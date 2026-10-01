import Foundation
import Testing
@testable import JTMCore

// `jtm prune workers`의 본체(WorkerPruner). Orca 출력이나 handle은 가짜 값이다.

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct WorkerPruneTests {
    private let workerTitle = "You are working inside Orca, a multi-agent IDE. You are a dispatched worker."
    private let wrappedTitle = "Please carry out this task from my Orca coordinator by following"

    /// 정리 대상이 섞인 DB: 이름 순서대로 티켓 id를 돌려준다.
    private func seed(_ store: Store) throws -> [String: Int64] {
        var ids: [String: Int64] = [:]
        @discardableResult
        func add(_ name: String, title: String, status: TicketStatus = .inbox, session: String? = nil, handle: String? = nil,
                 pinned: Bool = false, next: String? = nil) throws -> Int64 {
            let ticket = try store.createTicket(NewTicket(title: title, status: status, nextAction: next, pinnedTitle: pinned))
            if let session {
                try store.addLocation(ticketId: ticket.id, locator: .claudeCode(.init(sessionId: session, cwd: "/Users/me/Work/app")), source: .hook, externalKey: "claude:\(session)")
            }
            if let handle {
                try store.addLocation(ticketId: ticket.id, locator: .orcaTerminal(.init(terminalHandle: handle, tabId: "tab-\(name)")), source: .hook, externalKey: "orca-tab:tab-\(name)")
            }
            ids[name] = ticket.id
            return ticket.id
        }
        try add("codexTitle", title: workerTitle, status: .waiting, session: "sa")
        try add("claudeTitle", title: wrappedTitle, status: .active, session: "sb")
        try add("byHandle", title: "Fix login", status: .waiting, session: "sc", handle: "term_w")
        try add("touchedPinned", title: workerTitle, session: "sd", pinned: true)
        try add("touchedNext", title: wrappedTitle, session: "se", next: "check")
        try add("done", title: workerTitle, status: .done, session: "sf")
        try add("ordinary", title: "Why is Orca slow?", status: .active, session: "sg")
        try add("ordinaryHandle", title: "Fix login", status: .waiting, session: "sh", handle: "term_u")
        try store.upsertOrcaWorkerHandle("term_w", runId: "run_1")
        return ids
    }

    @Test func dryRunListsWhatWouldGoAndChangesNothing() throws {
        try withStore { store, _, _ in
            let ids = try seed(store)
            let report = try WorkerPruner(store: store).prune(workers: nil, dryRun: true, now: now)
            #expect(report.removed.map(\.id) == [ids["codexTitle"]!, ids["claudeTitle"]!, ids["byHandle"]!])
            #expect(report.removed.map(\.reason) == [OrcaWorker.titleReason, OrcaWorker.titleReason, OrcaWorker.handleReason])
            #expect(report.removed.first?.sessionKeys == ["claude:sa"])
            #expect(report.keptTouched.map(\.id) == [ids["touchedPinned"]!, ids["touchedNext"]!, ids["done"]!])
            #expect(try store.listTickets().count == 8 && store.ignoredSessions().isEmpty)
        }
    }

    @Test func realRunRemovesOnlyUntouchedWorkerTicketsRecordsTheirSessionsAndIsIdempotent() throws {
        try withStore { store, _, _ in
            let ids = try seed(store)
            let report = try WorkerPruner(store: store).prune(workers: nil, dryRun: false, now: now)
            #expect(report.removed.count == 3)
            let remaining = Set(try store.listTickets().map(\.id))
            #expect(remaining == Set(["touchedPinned", "touchedNext", "done", "ordinary", "ordinaryHandle"].map { ids[$0]! }))
            #expect(try store.ignoredSessions().map(\.externalKey) == ["claude:sa", "claude:sb", "claude:sc"])
            #expect(try store.ignoredSessions().map(\.reason) == [OrcaWorker.titleReason, OrcaWorker.titleReason, OrcaWorker.handleReason])
            let again = try WorkerPruner(store: store).prune(workers: nil, dryRun: false, now: now)
            #expect(again.removed.isEmpty && again.keptTouched.count == 3)
        }
    }

    @Test func freshlyReadHandlesAreUsedInTheSameRunAndOnlyWrittenForARealRun() throws {
        try withStore { store, _, _ in
            let ids = try seed(store)
            let fetch = WorkerFetch(workers: [.init(handle: "term_u", runId: "run_2")], runsScanned: 1)
            let dry = try WorkerPruner(store: store).prune(workers: fetch, dryRun: true, now: now)
            #expect(dry.removed.map(\.id).contains(ids["ordinaryHandle"]!))
            #expect(dry.workerRefresh == WorkerRefreshReport(runs: 1, handles: 1, error: nil))
            #expect(try !store.isOrcaWorkerHandle("term_u"))
            _ = try WorkerPruner(store: store).prune(workers: fetch, dryRun: false, now: now)
            #expect(try store.isOrcaWorkerHandle("term_u") && !store.listTickets().contains { $0.id == ids["ordinaryHandle"]! })
        }
    }

    @Test func aTicketWhoseSessionIsAlreadyIgnoredIsPrunedToo() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(NewTicket(title: "Fix login", status: .waiting))
            try store.addLocation(ticketId: ticket.id, locator: .claudeCode(.init(sessionId: "sz", cwd: "/Users/me/Work/app")), source: .hook, externalKey: "claude:sz")
            try store.ignoreSession("claude:sz", reason: "orca-worker-prompt")
            let report = try WorkerPruner(store: store).prune(workers: nil, dryRun: false, now: now)
            #expect(try report.removed.map(\.reason) == [OrcaWorker.sessionReason] && store.listTickets().isEmpty)
        }
    }
}
