import Foundation

/// `wwi prune workers`가 한 일(또는 `--dry-run`이면 할 일).
public struct PruneReport: Equatable, Sendable, Encodable {
    public struct Entry: Equatable, Sendable, Encodable {
        public var id: Int64
        public var title: String
        public var status: TicketStatus
        /// 왜 워커 티켓으로 봤는지: `orca-worker-title`, `orca-worker-handle`, `ignored-session`.
        public var reason: String
        /// 무시 목록에 남긴(남길) 세션 키.
        public var sessionKeys: [String]
    }

    public var removed: [Entry] = []
    /// 워커 티켓으로 보이지만 사용자가 손대서 남긴 것.
    public var keptTouched: [Entry] = []
    public var workerRefresh: WorkerRefreshReport?

    public init() {}
}

/// 이미 쌓인 워커 티켓을 한 번에 정리한다(`docs/01-product/auto-capture.md`): 제목이 워커 안내문으로 시작하거나,
/// 탭이 워커 터미널이거나, 이미 무시하기로 한 세션이 붙은 티켓 중 **사용자가 손대지 않은 것만** 지우고 그 세션 키를 무시 목록에 남긴다.
public struct WorkerPruner {
    private let store: Store

    public init(store: Store) { self.store = store }

    /// `workers`는 방금 조회한 워커 handle이다(nil이면 저장된 handle만 쓴다). `dryRun`이면 같은 일을 하고 롤백한다.
    public func prune(workers: WorkerFetch?, dryRun: Bool, now: Date) throws -> PruneReport {
        dryRun
            ? try store.rollbackTransaction { try run(workers: workers, now: now) }
            : try store.transaction { try run(workers: workers, now: now) }
    }

    private func run(workers: WorkerFetch?, now: Date) throws -> PruneReport {
        var report = PruneReport()
        if let workers { report.workerRefresh = try OrcaWorkers.record(workers, in: store, now: now) }
        let handles = try store.orcaWorkerHandles()

        for ticket in try store.listTickets().sorted(by: { $0.id < $1.id }) {
            let locations = try store.locations(ticketId: ticket.id)
            let keys = OrcaWorker.sessionKeys(of: locations)
            let reason: String
            if OrcaWorker.hasWorkerTitle(ticket.title) {
                reason = OrcaWorker.titleReason
            } else if locations.contains(where: { location in
                if case .orcaTerminal(let terminal) = location.locator { return handles.contains(terminal.terminalHandle) }
                return false
            }) {
                reason = OrcaWorker.handleReason
            } else if try keys.contains(where: { try store.isSessionIgnored($0) }) {
                reason = OrcaWorker.sessionReason
            } else {
                continue
            }
            let entry = PruneReport.Entry(id: ticket.id, title: ticket.title, status: ticket.status, reason: reason, sessionKeys: keys)
            if try OrcaWorker.removeIfUntouched(ticketId: ticket.id, store: store, reason: reason) != nil {
                report.removed.append(entry)
            } else {
                report.keptTouched.append(entry)
            }
        }
        return report
    }
}
