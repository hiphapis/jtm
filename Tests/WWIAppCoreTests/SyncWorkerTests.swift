import Foundation
import Testing
@testable import WWIAppCore
@testable import WWICore

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = epoch
    var current: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private func snapshotWithOneAgent() -> OrcaSnapshot {
    OrcaSnapshot(
        agents: [.init(paneKey: "tab-9:leaf-1", state: "idle", agentType: "claude", worktreePath: "/w/app")],
        terminals: [.init(handle: "term_9", tabId: "tab-9", leafId: "leaf-1", title: "Fix the login bug", worktreePath: "/w/app")],
        truncated: false)
}

@Suite struct SyncGateTests {
    @Test func openIsDebouncedFiveSecondsButTimerAndManualAreNot() {
        var gate = SyncGate()
        func start(_ trigger: SyncTrigger, at seconds: TimeInterval, finish: Bool = true) -> Bool {
            let date = epoch.addingTimeInterval(seconds)
            let allowed = gate.begin(trigger, now: date)
            if allowed && finish { gate.finish(now: date) }
            return allowed
        }
        #expect(start(.open, at: 0))
        #expect(!start(.open, at: 4.9))
        #expect(start(.open, at: 5))
        #expect(start(.timer, at: 6))
        #expect(start(.manual, at: 6))
    }

    @Test func onlyOneSyncRunsAtATime() {
        var gate = SyncGate()
        let first = gate.begin(.timer, now: epoch)
        #expect(first)
        for trigger in [SyncTrigger.timer, .open, .manual] {
            let blocked = !gate.begin(trigger, now: epoch.addingTimeInterval(100))
            #expect(blocked)
        }
        gate.finish(now: epoch.addingTimeInterval(1))
        let again = gate.begin(.manual, now: epoch.addingTimeInterval(2))
        #expect(again)
    }
}

@Suite(.korean) struct SyncWorkerTests {
    @Test func aSuccessfulSyncMergesTheSnapshotIntoTheDatabase() async throws {
        try await withTempDB { path in
            let worker = SyncWorker(databasePath: path, fetch: { snapshotWithOneAgent() }, isOrcaRunning: { true })
            let outcome = try #require(await worker.sync(.manual))
            guard case .synced(let summary) = outcome else { Issue.record("\(outcome)"); return }
            #expect(summary.created == 1)
            let tickets = try Store(path: path).listTickets()
            #expect(tickets.map(\.title) == ["Fix the login bug"])
            #expect(outcome.footerNotice == nil)
        }
    }

    @Test func workerHandlesReadDuringASyncKeepThatTerminalOutOfTheDatabase() async throws {
        try await withTempDB { path in
            let read = WorkerFetch(workers: [.init(handle: "term_9", runId: "run_1")], runsScanned: 1)
            let worker = SyncWorker(databasePath: path, fetch: { snapshotWithOneAgent() }, fetchWorkers: { _, _ in read }, isOrcaRunning: { true })
            let outcome = try #require(await worker.sync(.manual))
            guard case .synced(let summary) = outcome else { Issue.record("\(outcome)"); return }
            #expect(summary.created == 0 && summary.workersIgnored == 1)
            #expect(summary.workerRefresh == WorkerRefreshReport(runs: 1, handles: 1, error: nil))
            #expect(try Store(path: path).listTickets().isEmpty && Store(path: path).isOrcaWorkerHandle("term_9"))
        }
    }

    @Test func aFailedWorkerReadNeverFailsTheSyncAndTheSyncGateDoesNotBackOff() async throws {
        try await withTempDB { path in
            let worker = SyncWorker(
                databasePath: path, fetch: { snapshotWithOneAgent() }, fetchWorkers: { _, _ in WorkerFetch(error: "boom") }, isOrcaRunning: { true })
            let outcome = try #require(await worker.sync(.timer))
            guard case .synced(let summary) = outcome else { Issue.record("\(outcome)"); return }
            #expect(summary.created == 1 && summary.workerRefresh?.error == "boom" && outcome.footerNotice == nil)
            #expect(await worker.sync(.timer) != nil)  // 실패로 세지 않아서 백오프가 없다
        }
    }

    @Test func anUnreachableOrMissingOrcaIsQuietAndTouchesNothing() async throws {
        let failures: [any Error] = [
            SyncError.commandFailed(command: "orca worktree ps", detail: "exit 1"),
            SyncError.badResponse(command: "orca terminal list", detail: "junk"),
        ]
        for failure in failures {
            try await withTempDB { path in
                let worker = SyncWorker(databasePath: path, fetch: { throw failure }, isOrcaRunning: { true })
                let outcome = await worker.sync(.timer)
                #expect(outcome == .orcaUnavailable)
                #expect(outcome?.footerNotice == "Orca 연결 안 됨")
                #expect(!FileManager.default.fileExists(atPath: path))  // 실패하면 DB를 열지도 않는다
            }
        }
    }

    @Test func aDatabaseFailureIsReportedAsFailedNotAsOrcaUnavailable() async throws {
        let worker = SyncWorker(databasePath: "/dev/null/nope/jtm.sqlite", fetch: { snapshotWithOneAgent() }, isOrcaRunning: { true })
        let outcome = try #require(await worker.sync(.manual))
        guard case .failed = outcome else { Issue.record("\(outcome)"); return }
        #expect(outcome.footerNotice == "동기화 실패")
    }

    @Test func openTriggeredSyncsWithinFiveSecondsAreSkippedButManualIsNot() async throws {
        try await withTempDB { path in
            let clock = Clock()
            let calls = Counter()
            let worker = SyncWorker(databasePath: path, fetch: { calls.increment(); return snapshotWithOneAgent() }, isOrcaRunning: { true }, clock: { clock.current })
            #expect(await worker.sync(.open) != nil)
            clock.advance(3)
            #expect(await worker.sync(.open) == nil)
            #expect(await worker.sync(.manual) != nil)
            clock.advance(10)
            #expect(await worker.sync(.open) != nil)
            #expect(calls.value == 3)
        }
    }

    @Test func aSyncNeverRunsOnTheMainThread() async throws {
        try await withTempDB { path in
            let onMain = Counter()
            let worker = SyncWorker(databasePath: path, fetch: {
                if Thread.isMainThread { onMain.increment() }
                return snapshotWithOneAgent()
            }, isOrcaRunning: { true })
            _ = await worker.sync(.manual)
            #expect(onMain.value == 0)
        }
    }

    /// 벽시계 없이 결정적이다: 첫 동기화의 fetch가 "시작했다"고 알리고 **테스트가 풀어 줄 때까지** 막혀 있는다.
    /// 시작 신호를 받은 뒤에야 두 번째·세 번째 요청을 보내므로 "이미 돌고 있다"가 항상 참이다.
    @Test func concurrentRequestsRunOnceAndAManualOneIsToldTheSyncIsBusy() async throws {
        try await withTempDB { path in
            let calls = Counter()
            let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let worker = SyncWorker(databasePath: path, fetch: {
                calls.increment()
                started.signal()
                _ = release.wait(timeout: .now() + 10)  // 테스트가 풀어 준다(안전장치로만 10초 상한)
                return snapshotWithOneAgent()
            }, isOrcaRunning: { true })
            let first = Task { await worker.sync(.timer) }
            // fetch 안으로 들어갈 때까지 기다린다(시간 가정 없음).
            let didStart = await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: started.wait(timeout: .now() + 10) == .success) }
            }
            #expect(didStart)
            let manual = await worker.sync(.manual)
            let timer = await worker.sync(.timer)
            release.signal()
            let firstOutcome = await first.value
            guard case .synced = try #require(firstOutcome) else { Issue.record("\(String(describing: firstOutcome))"); return }
            #expect(manual == .busy && manual?.footerNotice == "동기화 중…")
            #expect(timer == nil)  // 자동 실행은 조용히 건너뛴다
            #expect(calls.value == 1)
        }
    }

    /// Orca를 쓰지 않는 Mac: 프로세스도 띄우지 않고 DB도 열지 않고, 푸터에 아무것도 띄우지 않는다(결과가 nil).
    @Test func aMachineWithoutOrcaSkipsSyncSilently() async throws {
        try await withTempDB { path in
            let calls = Counter()
            let worker = SyncWorker(
                databasePath: path, fetch: { calls.increment(); return snapshotWithOneAgent() },
                isOrcaRunning: { true }, isOrcaInstalled: { false })
            #expect(await worker.sync(.timer) == nil)
            #expect(await worker.sync(.manual) == nil)
            #expect(calls.value == 0 && !FileManager.default.fileExists(atPath: path))
        }
        // 설치돼 있다고 믿었는데 CLI를 못 찾으면(막 지웠다) 그것도 조용히 넘어간다.
        try await withTempDB { path in
            let worker = SyncWorker(databasePath: path, fetch: { throw SyncError.orcaNotFound }, isOrcaRunning: { true })
            #expect(await worker.sync(.timer) == nil)
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    // MARK: S4

    @Test func whenOrcaIsNotRunningNoCommandIsSpawnedAndItIsNotAFailure() async throws {
        try await withTempDB { path in
            let clock = Clock()
            let calls = Counter()
            let running = Flag()
            let worker = SyncWorker(
                databasePath: path, fetch: { calls.increment(); return snapshotWithOneAgent() },
                isOrcaRunning: { running.value }, clock: { clock.current })
            #expect(await worker.sync(.timer) == .orcaUnavailable)
            #expect(await worker.sync(.timer) == .orcaUnavailable)  // 백오프가 없다: 검사가 싸다
            #expect(calls.value == 0)
            #expect(!FileManager.default.fileExists(atPath: path))
            running.value = true
            guard case .synced = try #require(await worker.sync(.timer)) else { Issue.record("not synced"); return }
            #expect(calls.value == 1)
        }
    }

    @Test func consecutiveFailuresBackOffTimerAndOpenSyncsButNotManualOnes() async throws {
        try await withTempDB { path in
            let clock = Clock()
            let calls = Counter()
            let worker = SyncWorker(
                databasePath: path, fetch: { calls.increment(); throw SyncError.commandFailed(command: "orca worktree ps", detail: "exit 1") },
                isOrcaRunning: { true }, clock: { clock.current })
            #expect(await worker.sync(.timer) == .orcaUnavailable)  // 실패 1: 다음은 30초 뒤
            clock.advance(29)
            #expect(await worker.sync(.timer) == nil)
            clock.advance(10)
            #expect(await worker.sync(.open) == .orcaUnavailable)  // 39초: 백오프가 끝났으니 두 번째 시도(실패 2: 다음은 60초 뒤)
            #expect(calls.value == 2)
            clock.advance(50)
            #expect(await worker.sync(.timer) == nil)
            #expect(await worker.sync(.manual) == .orcaUnavailable)  // 사용자가 직접 누르면 백오프를 무시한다
            #expect(calls.value == 3)
        }
    }

    @Test func aSuccessResetsTheBackoff() async throws {
        try await withTempDB { path in
            let clock = Clock()
            let fail = Flag(true)
            let worker = SyncWorker(
                databasePath: path,
                fetch: { if fail.value { throw SyncError.commandFailed(command: "orca", detail: "x") }; return snapshotWithOneAgent() },
                isOrcaRunning: { true }, clock: { clock.current })
            _ = await worker.sync(.timer)
            clock.advance(31)
            fail.value = false
            guard case .synced = try #require(await worker.sync(.timer)) else { Issue.record("not synced"); return }
            #expect(await worker.sync(.timer) != nil)  // 바로 다음 자동 실행도 막히지 않는다
        }
    }

    @Test func theAppUsesAnEightSecondPerCommandTimeout() {
        #expect(SyncWorker.commandTimeout == 8)
    }
}

@Suite struct SyncBackoffTests {
    @Test func backoffDoublesFromThirtySecondsUpToFiveMinutes() {
        #expect((0...8).map { SyncGate.backoff(afterFailures: $0) } == [0, 30, 60, 120, 240, 300, 300, 300, 300])
        #expect(SyncGate.backoff(afterFailures: 10_000) == 300)
    }

    @Test func theGateReportsBusyOnlyToManualRequests() {
        var gate = SyncGate()
        #expect(gate.decide(.timer, now: epoch) == .run)
        #expect(gate.decide(.manual, now: epoch) == .busy)
        #expect(gate.decide(.timer, now: epoch) == .skip)
        #expect(gate.decide(.open, now: epoch) == .skip)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool
    init(_ value: Bool = false) { flag = value }
    var value: Bool { get { lock.withLock { flag } } set { lock.withLock { flag = newValue } } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
