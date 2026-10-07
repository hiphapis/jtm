import AppKit
import Foundation
import JTMCore
import os

public enum SyncTrigger: Sendable {
    /// 30초 타이머.
    case timer
    /// 팝오버를 열 때(마지막 동기화 후 5초 안이면 건너뛴다).
    case open
    /// 하단 메뉴의 "지금 동기화".
    case manual
}

public enum SyncOutcome: Equatable, Sendable {
    case synced(SyncSummary)
    /// Orca가 설치돼 있지만 떠 있지 않거나 응답하지 않는다. 조용히 건너뛰고 팝오버 아래에 작게 알린다(Orca가 아예 없으면 알리지도 않는다).
    case orcaUnavailable
    /// DB에 병합하지 못했다.
    case failed(String)
    /// 이미 동기화가 돌고 있어서 "지금 동기화" 요청을 받지 못했다.
    case busy

    /// 팝오버 하단에 작게 보이는 문구. 정상이면 nil.
    public var footerNotice: String? {
        switch self {
        case .synced: nil
        case .orcaUnavailable: L10n.string(.syncOrcaUnavailable)
        case .failed: L10n.string(.syncFailed)
        case .busy: L10n.string(.syncBusy)
        }
    }
}

/// 동기화를 언제 돌릴지 정하는 순수 규칙: 한 번에 하나만, 팝오버 열기는 5초 디바운스, 연속 실패하면 백오프.
public struct SyncGate: Sendable {
    public static let openDebounce: TimeInterval = 5
    /// 연속 실패 뒤 다음 자동 실행까지: 30초에서 시작해 두 배씩, 최대 5분.
    public static let backoffBase: TimeInterval = 30
    public static let backoffMax: TimeInterval = 300

    public enum Decision: Equatable, Sendable {
        case run
        /// 돌고 있는 동기화가 있어서 못 돌린다(사용자가 직접 요청했으면 알려야 한다).
        case busy
        /// 조용히 건너뛴다(디바운스, 백오프, 다른 동기화가 도는 중인 자동 실행).
        case skip
    }

    public private(set) var lastFinished: Date?
    public private(set) var inFlight = false
    public private(set) var consecutiveFailures = 0
    public private(set) var retryNotBefore: Date?

    public init() {}

    public static func backoff(afterFailures count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        return min(backoffBase * pow(2, Double(min(count, 16) - 1)), backoffMax)
    }

    /// 돌려도 되면 `.run`(그리고 실행 중으로 표시한다). 사용자가 직접 요청한 것(`.manual`)은 디바운스와 백오프를 무시한다.
    public mutating func decide(_ trigger: SyncTrigger, now: Date) -> Decision {
        guard !inFlight else { return trigger == .manual ? .busy : .skip }
        if trigger == .open, let last = lastFinished, now.timeIntervalSince(last) < Self.openDebounce { return .skip }
        if trigger != .manual, let retry = retryNotBefore, now < retry { return .skip }
        inFlight = true
        return .run
    }

    public mutating func begin(_ trigger: SyncTrigger, now: Date) -> Bool { decide(trigger, now: now) == .run }

    public mutating func finish(now: Date, failed: Bool = false) {
        inFlight = false
        lastFinished = now
        if failed {
            consecutiveFailures += 1
            retryNotBefore = now.addingTimeInterval(Self.backoff(afterFailures: consecutiveFailures))
        } else {
            consecutiveFailures = 0
            retryNotBefore = nil
        }
    }
}

/// Orca 앱이 떠 있는가. 안 떠 있으면 동기화가 `orca` CLI 프로세스를 띄울 이유가 없다.
public enum OrcaApp {
    public static let bundleIdentifier = "com.stablyai.orca"

    public static func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }
}

/// Orca 폴러를 백그라운드 큐에서 실행한다(메인 스레드 금지). 읽기 전용 Orca 명령으로 스냅샷을 받고 `OrcaSync`로 병합한다.
public final class SyncWorker: @unchecked Sendable {
    public typealias Fetch = @Sendable () throws -> OrcaSnapshot
    /// 워커 터미널 handle을 조회한다(5분 제한은 안에서 건다). 조회하지 않으면 nil. 던지지 않는다: 실패는 `WorkerFetch.error`에 담는다.
    public typealias FetchWorkers = @Sendable (Store, Date) -> WorkerFetch?

    /// 앱의 동기화는 명령마다 8초까지만 기다린다(CLI의 `jtm sync`는 20초).
    public static let commandTimeout: TimeInterval = 8

    /// 실제 Orca CLI에서 스냅샷을 읽는다(`worktree ps`, `terminal list`: 둘 다 읽기 전용).
    public static let liveFetch: Fetch = {
        guard let orca = OrcaCLI.locate() else { throw SyncError.orcaNotFound }
        return try OrcaSnapshot.fetch(runner: ProcessRunner(), orca: orca, timeout: commandTimeout)
    }

    /// 실제 Orca CLI에서 워커 handle을 읽는다(`orchestration run-list`, `worker-list`: 읽기 전용). 앱은 전체 조회에 20초까지만 쓴다.
    public static let liveFetchWorkers: FetchWorkers = { store, now in
        guard OrcaWorkers.isRefreshDue(store: store, now: now), let orca = OrcaCLI.locate() else { return nil }
        return OrcaWorkers.fetch(runner: ProcessRunner(), orca: orca, now: now, timeout: commandTimeout, budget: 20)
    }

    private static let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "sync")

    private let databasePath: String
    private let fetch: Fetch
    private let fetchWorkers: FetchWorkers
    private let isOrcaRunning: @Sendable () -> Bool
    private let isOrcaInstalled: @Sendable () -> Bool
    private let clock: @Sendable () -> Date
    private let queue = DispatchQueue(label: "jtm.app.sync", qos: .utility)
    private let lock = NSLock()
    private var gate = SyncGate()

    public init(
        databasePath: String, fetch: @escaping Fetch = SyncWorker.liveFetch,
        fetchWorkers: @escaping FetchWorkers = { _, _ in nil },
        isOrcaRunning: @escaping @Sendable () -> Bool = OrcaApp.isRunning,
        isOrcaInstalled: @escaping @Sendable () -> Bool = { true },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.databasePath = databasePath
        self.fetch = fetch
        self.fetchWorkers = fetchWorkers
        self.isOrcaRunning = isOrcaRunning
        self.isOrcaInstalled = isOrcaInstalled
        self.clock = clock
    }

    /// 실행했으면 결과, 조용히 건너뛰었으면 nil, 사용자가 직접 요청했는데 이미 돌고 있으면 `.busy`.
    public func sync(_ trigger: SyncTrigger) async -> SyncOutcome? {
        let decision = lock.withLock { gate.decide(trigger, now: clock()) }
        switch decision {
        case .skip: return nil
        case .busy: return .busy
        case .run: break
        }
        let (outcome, failed) = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.perform()) }
        }
        lock.withLock { gate.finish(now: clock(), failed: failed) }
        return outcome
    }

    /// 실패(재시도를 늦춰야 하는 것)는 명령이 실패했거나 DB에 병합하지 못한 경우다. Orca 앱이 안 떠 있거나 CLI가 없는 것은
    /// 프로세스를 띄우지 않고 끝나므로 실패로 세지 않는다.
    /// Orca를 쓰지 않는 사람(CLI가 없다)에게는 알림도 없다: 결과가 nil이다.
    private func perform() -> (SyncOutcome?, failed: Bool) {
        guard isOrcaInstalled() else { return (nil, false) }
        guard isOrcaRunning() else { return (.orcaUnavailable, false) }
        let snapshot: OrcaSnapshot
        do { snapshot = try fetch() } catch {
            if case SyncError.orcaNotFound = error { return (nil, false) }
            Self.log.error("orca fetch failed: \(String(describing: error), privacy: .private)")
            return (.orcaUnavailable, true)
        }
        do {
            let store = try Store(path: databasePath, onWarning: { _ in })
            let now = clock()
            // 워커 조회는 실패해도 동기화를 실패시키지 않는다(요약에만 남는다). DB 쓰기 잠금을 잡기 전에 한다.
            let workers = fetchWorkers(store, now)
            return (.synced(try OrcaSync(store: store).apply(snapshot, workers: workers, now: now)), false)
        } catch {
            Self.log.error("orca merge failed: \(String(describing: error), privacy: .private)")
            return (.failed("\(error)"), true)
        }
    }
}
