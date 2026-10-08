import Foundation

/// 한 번의 워커 handle 조회 결과. 읽기 전용 Orca 명령(`orchestration run-list`, `worker-list`)만 쓴다.
public struct WorkerFetch: Equatable, Sendable {
    public struct Worker: Equatable, Sendable {
        public var handle: String
        public var runId: String
    }

    public var workers: [Worker]
    /// `worker-list`를 조회한 실행 기록(run) 수.
    public var runsScanned: Int
    /// 일부라도 못 읽었으면 그 이유(한 줄). 읽은 만큼의 handle은 `workers`에 있다.
    public var error: String?

    public init(workers: [Worker] = [], runsScanned: Int = 0, error: String? = nil) {
        self.workers = workers
        self.runsScanned = runsScanned
        self.error = error
    }
}

/// `SyncSummary`에 실리는 조회 결과 요약.
public struct WorkerRefreshReport: Equatable, Sendable, Encodable {
    public var runs: Int
    public var handles: Int
    public var error: String?
}

/// Orca 오케스트레이션 워커의 터미널 handle을 모은다(`docs/01-product/auto-capture.md`).
/// 실행 기록이 많아서(실측 16개) 매번 조회하지 않는다: 최근 24시간 안에 바뀐 실행 기록만, 시도 후 5분이 지나야 다시 조회한다.
/// 이 조회가 실패해도 동기화 전체는 실패가 아니다: 실패는 요약에 실린다(`WorkerFetch.error`).
public enum OrcaWorkers {
    public static let refreshInterval: TimeInterval = 5 * 60
    public static let runWindow: TimeInterval = 24 * 60 * 60
    /// 마지막 조회 시도(성공이든 실패든) 시각. 이 값으로 5분 제한을 건다.
    static let attemptKey = "orca_worker_refresh_at"
    /// 마지막으로 끝까지 성공한 조회 시각(참고용).
    static let successKey = "orca_worker_refresh_ok_at"

    private static let pageLimit = "100"
    private static let maxPages = 20

    /// 마지막 시도로부터 `refreshInterval`이 지났거나 기록이 없으면 true. 시계가 뒤로 갔어도 true.
    public static func isRefreshDue(store: Store, now: Date) -> Bool {
        guard let raw = (try? store.meta(attemptKey)) ?? nil, let last = Double(raw) else { return true }
        let elapsed = now.timeIntervalSince1970 - last
        return elapsed < 0 || elapsed >= refreshInterval
    }

    /// 조회 결과를 DB에 반영한다(호출하는 쪽이 트랜잭션을 잡는다). 시도 시각은 실패해도 남겨서 다음 5분 동안은 다시 시도하지 않는다.
    @discardableResult
    static func record(_ fetch: WorkerFetch, in store: Store, now: Date) throws -> WorkerRefreshReport {
        for worker in fetch.workers { try store.upsertOrcaWorkerHandle(worker.handle, runId: worker.runId) }
        let stamp = String(Int64(now.timeIntervalSince1970))
        try store.setMeta(attemptKey, stamp)
        if fetch.error == nil { try store.setMeta(successKey, stamp) }
        return WorkerRefreshReport(runs: fetch.runsScanned, handles: fetch.workers.count, error: fetch.error)
    }

    // MARK: Argv

    public static func runListArgv(_ orca: String, cursor: String? = nil) -> [String] {
        [orca, "orchestration", "run-list", "--json", "--limit", pageLimit] + (cursor.map { ["--cursor", $0] } ?? [])
    }

    public static func workerListArgv(_ orca: String, run: String, cursor: String? = nil) -> [String] {
        [orca, "orchestration", "worker-list", "--run", run, "--json", "--limit", pageLimit]
            + (cursor.map { ["--cursor", $0] } ?? [])
    }

    // MARK: Fetch

    /// 최근 `runWindow` 안에 바뀐 실행 기록의 워커 handle을 모두 읽는다. 던지지 않는다.
    /// `timeout`은 명령마다, `budget`은 전체에 적용된다(다 못 읽으면 읽은 만큼 돌려주고 이유를 남긴다).
    public static func fetch(
        runner: CommandRunner, orca: String, now: Date, timeout: TimeInterval = OrcaSnapshot.commandTimeout,
        budget: TimeInterval = 60
    ) -> WorkerFetch {
        let started = Date()
        var result = WorkerFetch()
        var errors: [String] = []

        let runs: [Run]
        do { runs = try listRuns(runner: runner, orca: orca, timeout: timeout, budget: budget, started: started) } catch {
            result.error = "\(error)"
            return result
        }
        let recent = runs
            .filter { run in run.updatedAt.map { now.timeIntervalSince($0) <= runWindow } ?? true }  // 읽을 수 없는 시각은 최근으로 본다
            .sorted { ($0.updatedAt ?? .distantFuture) > ($1.updatedAt ?? .distantFuture) }
        var seen = Set<String>()
        for run in recent {
            if Date().timeIntervalSince(started) > budget {
                errors.append("time budget exceeded before all runs were read")
                break
            }
            do {
                for handle in try listWorkerHandles(
                    runner: runner, orca: orca, run: run.id, timeout: timeout, budget: budget, started: started)
                where seen.insert(handle).inserted {
                    result.workers.append(.init(handle: handle, runId: run.id))
                }
                result.runsScanned += 1
            } catch {
                errors.append("\(error)")
            }
        }
        if let first = errors.first { result.error = errors.count == 1 ? first : "\(first) (+\(errors.count - 1) more)" }
        return result
    }

    private struct Run {
        var id: String
        var updatedAt: Date?
    }

    private static func listRuns(
        runner: CommandRunner, orca: String, timeout: TimeInterval, budget: TimeInterval, started: Date
    ) throws -> [Run] {
        var runs: [Run] = []
        var cursor: String?
        for _ in 0..<maxPages {
            let page = try decode(
                RunListResult.self, runner: runner, argv: runListArgv(orca, cursor: cursor), timeout: timeout)
            runs += page.runs.compactMap(\.value).map { Run(id: $0.id, updatedAt: $0.updatedAt.flatMap(parseDate)) }
            guard let next = page.nextCursor, !next.isEmpty, next != cursor,
                  Date().timeIntervalSince(started) <= budget else { break }
            cursor = next
        }
        return runs
    }

    private static func listWorkerHandles(
        runner: CommandRunner, orca: String, run: String, timeout: TimeInterval, budget: TimeInterval, started: Date
    ) throws -> [String] {
        var handles: [String] = []
        var cursor: String?
        for _ in 0..<maxPages {
            let page = try decode(
                WorkerListResult.self, runner: runner, argv: workerListArgv(orca, run: run, cursor: cursor), timeout: timeout)
            handles += page.workers.compactMap(\.value).compactMap(\.terminalHandle)
            guard page.page?.hasMore == true, let next = page.page?.nextCursor, !next.isEmpty, next != cursor,
                  Date().timeIntervalSince(started) <= budget else { break }
            cursor = next
        }
        return handles
    }

    private static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    // MARK: Wire format (필요한 필드만, 나머지는 무시)

    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    private struct Envelope<Result: Decodable>: Decodable {
        struct Failure: Decodable { var code: String?; var message: String? }
        var ok: Bool?
        var result: Result?
        var error: Failure?
    }

    private struct RunListResult: Decodable {
        var runs: [Lossy<RawRun>]
        var nextCursor: String?

        private enum CodingKeys: String, CodingKey { case runs, nextCursor }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            runs = try c.decode([Lossy<RawRun>].self, forKey: .runs)
            nextCursor = try? c.decodeIfPresent(String.self, forKey: .nextCursor)
        }
    }

    private struct RawRun: Decodable {
        var id: String
        var updatedAt: String?

        private enum CodingKeys: String, CodingKey { case id, updatedAt = "updated_at" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            guard !id.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "empty") }
            updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
        }
    }

    private struct WorkerListResult: Decodable {
        struct Page: Decodable {
            var hasMore: Bool?
            var nextCursor: String?
            private enum CodingKeys: String, CodingKey { case hasMore, nextCursor }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                hasMore = try? c.decodeIfPresent(Bool.self, forKey: .hasMore)
                nextCursor = try? c.decodeIfPresent(String.self, forKey: .nextCursor)
            }
        }

        var workers: [Lossy<RawWorker>]
        var page: Page?

        private enum CodingKeys: String, CodingKey { case workers, page }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            workers = try c.decode([Lossy<RawWorker>].self, forKey: .workers)
            page = try? c.decodeIfPresent(Page.self, forKey: .page)
        }
    }

    private struct RawWorker: Decodable {
        struct Resource: Decodable {
            var terminalHandle: String?
            private enum CodingKeys: String, CodingKey { case terminalHandle }
            init(from decoder: Decoder) throws {
                terminalHandle = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .terminalHandle)
            }
        }

        var agentTerminalHandle: String?
        var resource: Resource?
        /// 반납된 워커도 handle이 남아 있다(실측). 없으면 `resource.terminalHandle`.
        var terminalHandle: String? {
            [agentTerminalHandle, resource?.terminalHandle].compactMap { $0 }.first { !$0.isEmpty }
        }

        private enum CodingKeys: String, CodingKey { case agentTerminalHandle, resource }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentTerminalHandle = try? c.decodeIfPresent(String.self, forKey: .agentTerminalHandle)
            resource = try? c.decodeIfPresent(Resource.self, forKey: .resource)
        }
    }

    private static func decode<Result: Decodable>(
        _ type: Result.Type, runner: CommandRunner, argv: [String], timeout: TimeInterval
    ) throws -> Result {
        let command = argv.dropFirst().prefix(2).joined(separator: " ")
        let output = runner.run(argv, stdin: nil, timeout: timeout)
        guard output.succeeded else {
            let text = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SyncError.commandFailed(
                command: "orca \(command)", detail: text.isEmpty ? "exit \(output.exitCode)" : "exit \(output.exitCode): \(text)")
        }
        let envelope: Envelope<Result>
        do { envelope = try JSONDecoder().decode(Envelope<Result>.self, from: Data(output.stdout.utf8)) } catch {
            throw SyncError.badResponse(command: "orca \(command)", detail: "not the expected JSON")
        }
        if envelope.ok == false {
            throw SyncError.commandFailed(
                command: "orca \(command)", detail: envelope.error.map { $0.message ?? $0.code ?? "error" } ?? "ok=false")
        }
        guard let result = envelope.result else { throw SyncError.badResponse(command: "orca \(command)", detail: "no result") }
        return result
    }
}
