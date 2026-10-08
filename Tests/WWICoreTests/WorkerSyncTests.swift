import Foundation
import Testing
@testable import WWICore

// 워커 handle 조회(`orchestration run-list`/`worker-list`), 폴러의 워커 처리, `wwi prune workers`의 본체.
// Orca 출력은 실측한 모양을 가짜 값으로 만든 것이다(실제 handle, run id는 넣지 않는다).

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func isoString(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

private func stamp(_ ago: TimeInterval) -> String { isoString(now.addingTimeInterval(-ago)) }

private func runListJSON(_ runs: [(id: String, updated: String)], next: String? = nil) -> CommandResult {
    let items = runs.map {
        #"{"id":"\#($0.id)","objective":"o","coordinator_handle":null,"consumer_generation":1,"legacy":0,"created_at":"\#($0.updated)","updated_at":"\#($0.updated)"}"#
    }
    let cursor = next.map { #""\#($0)""# } ?? "null"
    return CommandResult(exitCode: 0, stdout: #"{"id":"x","ok":true,"result":{"runs":[\#(items.joined(separator: ","))],"nextCursor":\#(cursor)}}"#)
}

/// `handles`의 nil은 handle이 없는 워커(agentTerminalHandle: null)이고, `viaResource`는 resource.terminalHandle로만 알려 주는 워커다.
private func workerListJSON(_ handles: [String?], viaResource: [String] = [], more: String? = nil) -> CommandResult {
    var items = handles.map { handle in
        #"{"dispatchId":"d","taskId":"t","runId":"r","workerState":"released","agentTerminalHandle":\#(handle.map { "\"\($0)\"" } ?? "null"),"resource":null}"#
    }
    items += viaResource.map {
        #"{"dispatchId":"d","taskId":"t","runId":"r","agentTerminalHandle":null,"resource":{"terminalHandle":"\#($0)"}}"#
    }
    let page = more.map { #"{"limit":100,"total":9,"hasMore":true,"nextCursor":"\#($0)"}"# } ?? #"{"limit":100,"total":1,"hasMore":false,"nextCursor":null}"#
    return CommandResult(exitCode: 0, stdout: #"{"id":"x","ok":true,"result":{"workers":[\#(items.joined(separator: ","))],"counts":{"retained":0,"released":1},"page":\#(page)}}"#)
}

@Suite struct OrcaWorkersFetchTests {
    @Test func readsHandlesOfRecentRunsOnlyAndOnlyWithReadOnlyCommands() {
        let runner = FakeRunner()
        runner.on(OrcaWorkers.runListArgv(orca), runListJSON([
            ("run_new", stamp(3600)), ("run_old", stamp(25 * 3600)), ("run_odd", "not a date"),
            ("run_frac", isoString(now.addingTimeInterval(-60)).replacingOccurrences(of: "Z", with: ".250Z")),
        ]))
        runner.on(OrcaWorkers.workerListArgv(orca, run: "run_new"), workerListJSON(["term_a", nil], viaResource: ["term_b"]))
        runner.on(OrcaWorkers.workerListArgv(orca, run: "run_odd"), workerListJSON(["term_a", "term_c"]))  // term_a는 한 번만
        runner.on(OrcaWorkers.workerListArgv(orca, run: "run_frac"), workerListJSON([]))

        let fetched = OrcaWorkers.fetch(runner: runner, orca: orca, now: now)
        #expect(fetched.error == nil && fetched.runsScanned == 3)
        // 읽을 수 없는 시각은 최근으로 보고 먼저, 나머지는 최근 것부터 읽는다. 같은 handle은 처음 본 run에 붙는다.
        #expect(fetched.workers == [
            .init(handle: "term_a", runId: "run_odd"), .init(handle: "term_c", runId: "run_odd"),
            .init(handle: "term_b", runId: "run_new"),
        ])
        // run_old는 24시간을 넘겨서 조회하지 않는다. 명령은 전부 읽기 전용 조회다.
        #expect(!runner.argvs.contains(OrcaWorkers.workerListArgv(orca, run: "run_old")))
        #expect(runner.argvs.allSatisfy { $0.dropFirst().prefix(2).joined(separator: " ") == "orchestration run-list" || $0.dropFirst().prefix(2).joined(separator: " ") == "orchestration worker-list" })
        #expect(runner.calls.allSatisfy { $0.stdin == nil && $0.timeout == OrcaSnapshot.commandTimeout })
    }

    @Test func followsCursorsOfBothListCommands() {
        let runner = FakeRunner()
        let second = OrcaWorkers.runListArgv(orca, cursor: "c1")
        runner.on(second, runListJSON([("run_2", stamp(60))]))  // 더 구체적인 규칙을 먼저 둔다
        runner.on(OrcaWorkers.runListArgv(orca), runListJSON([("run_1", stamp(30))], next: "c1"))
        runner.on(OrcaWorkers.workerListArgv(orca, run: "run_1", cursor: "w1"), workerListJSON(["term_2"]))
        runner.on(OrcaWorkers.workerListArgv(orca, run: "run_1"), workerListJSON(["term_1"], more: "w1"))
        runner.on(OrcaWorkers.workerListArgv(orca, run: "run_2"), workerListJSON(["term_3"]))
        let fetched = OrcaWorkers.fetch(runner: runner, orca: orca, now: now)
        #expect(fetched.error == nil && Set(fetched.workers.map(\.handle)) == ["term_1", "term_2", "term_3"])
        #expect(fetched.runsScanned == 2)
    }

    @Test func aRepeatedCursorDoesNotLoopForever() {
        let runner = FakeRunner()
        runner.on(OrcaWorkers.runListArgv(orca), runListJSON([("run_1", stamp(30))], next: "same"))
        runner.on(OrcaWorkers.runListArgv(orca, cursor: "same"), runListJSON([("run_2", stamp(30))], next: "same"))
        runner.on([orca, "orchestration", "worker-list"], workerListJSON([]))
        #expect(OrcaWorkers.fetch(runner: runner, orca: orca, now: now).runsScanned == 2)
    }

    @Test func aFailingRunListReturnsAnErrorInsteadOfThrowing() {
        for failure in [orcaNotReady, CommandResult(exitCode: 124, stderr: "timed out after 20s"), CommandResult(exitCode: 0, stdout: "junk")] {
            let runner = FakeRunner()
            runner.on([orca, "orchestration", "run-list"], failure)
            let fetched = OrcaWorkers.fetch(runner: runner, orca: orca, now: now)
            #expect(fetched.workers.isEmpty && fetched.error?.contains("orca orchestration run-list") == true, "\(String(describing: fetched.error))")
        }
    }

    @Test func aFailingWorkerListKeepsWhatTheOtherRunsGaveAndReportsTheError() {
        let runner = FakeRunner()
        runner.on(OrcaWorkers.runListArgv(orca), runListJSON([("run_1", stamp(10)), ("run_2", stamp(20))]))
        runner.on(OrcaWorkers.workerListArgv(orca, run: "run_1"), orcaNotReady)
        runner.on(OrcaWorkers.workerListArgv(orca, run: "run_2"), workerListJSON(["term_2"]))
        let fetched = OrcaWorkers.fetch(runner: runner, orca: orca, now: now)
        #expect(fetched.workers == [.init(handle: "term_2", runId: "run_2")] && fetched.runsScanned == 1)
        #expect(fetched.error?.contains("orca orchestration worker-list") == true)
    }

    @Test func aTimeBudgetStopsTheScanAndSaysSo() {
        let runner = FakeRunner()
        runner.on(OrcaWorkers.runListArgv(orca), runListJSON([("run_1", stamp(10))]))
        runner.on([orca, "orchestration", "worker-list"], workerListJSON(["term_1"]))
        let fetched = OrcaWorkers.fetch(runner: runner, orca: orca, now: now, budget: -1)
        #expect(fetched.workers.isEmpty && fetched.error?.contains("budget") == true)
    }

    // MARK: 5분 제한

    @Test func theRefreshGateIsFiveMinutesFromTheLastAttemptEvenIfItFailed() throws {
        try withStore { store, _, _ in
            #expect(OrcaWorkers.isRefreshDue(store: store, now: now))
            try OrcaWorkers.record(WorkerFetch(error: "boom"), in: store, now: now)  // 실패한 시도도 시각을 남긴다
            #expect(!OrcaWorkers.isRefreshDue(store: store, now: now.addingTimeInterval(299)))
            #expect(OrcaWorkers.isRefreshDue(store: store, now: now.addingTimeInterval(300)))
            #expect(OrcaWorkers.isRefreshDue(store: store, now: now.addingTimeInterval(-10)))  // 시계가 뒤로 갔다
            #expect(try store.meta(OrcaWorkers.successKey) == nil)  // 성공 시각은 성공했을 때만
            try OrcaWorkers.record(WorkerFetch(workers: [.init(handle: "term_1", runId: "run_1")], runsScanned: 1), in: store, now: now)
            #expect(try store.meta(OrcaWorkers.successKey) != nil && store.isOrcaWorkerHandle("term_1"))
        }
    }
}

// MARK: 폴러

private let wtId = "wt-uuid::/Users/me/Work/app-wt"

private func agent(_ tab: String, updated: Date = now) -> OrcaSnapshot.Agent {
    .init(paneKey: "\(tab):leaf-1", state: "working", agentType: "claude", updated: updated)
}

private extension OrcaSnapshot.Agent {
    init(paneKey: String, state: String?, agentType: String?, updated: Date) {
        self.init(paneKey: paneKey, state: state, agentType: agentType, prompt: nil, updatedAt: updated,
                  worktreeId: wtId, worktreePath: "/Users/me/Work/app-wt")
    }
}

private func terminal(_ tab: String, handle: String, title: String? = "✳ Fix login") -> OrcaSnapshot.Terminal {
    .init(handle: handle, ptyId: "pty-\(handle)", tabId: tab, leafId: "leaf-1", title: title, worktreeId: wtId,
          worktreePath: "/Users/me/Work/app-wt")
}

private struct NoProject: ProjectResolver {
    func gitTopLevel(containing cwd: String) -> String? { nil }
}

private func sessionEvent(_ kind: AgentEventKind, _ session: String = "s1", agent: AgentType = .claude) -> AgentEvent {
    AgentEvent(agent: agent, kind: kind, sessionId: session, cwd: "/Users/me/Work/app", prompt: nil)
}

@Suite struct WorkerPollerTests {
    private func hookTicket(_ store: Store, tab: String, handle: String, session: String = "s1") throws -> Int64 {
        let outcome = try Reconciler(store: store, projectResolver: NoProject()).apply(
            event: sessionEvent(.sessionStart, session), env: OrcaEnv(terminalHandle: handle, tabId: tab, worktreeId: wtId), now: now)
        return try #require(outcome).ticketId
    }

    @Test func noTicketIsCreatedForAWorkerTerminalButOthersAreAndItStaysThatWay() throws {
        try withStore { store, _, _ in
            try store.upsertOrcaWorkerHandle("term_w", runId: "run_1")
            let sync = OrcaSync(store: store)
            let snapshot = OrcaSnapshot(
                agents: [agent("tab-w"), agent("tab-u")], terminals: [terminal("tab-w", handle: "term_w"), terminal("tab-u", handle: "term_u")])
            for _ in 0..<2 {
                let summary = try sync.apply(snapshot, now: now)
                #expect(summary.workersIgnored == 1 && summary.skipped == 0)
                #expect(try store.location(byExternalKey: "orca-tab:tab-w") == nil)
                #expect(try store.listTickets().count == 1 && store.location(byExternalKey: "orca-tab:tab-u") != nil)
            }
            #expect(try sync.apply(snapshot, now: now).created == 0)
        }
    }

    @Test func anUntouchedTicketOnAWorkerTerminalIsRemovedAndItsSessionIsIgnored() throws {
        try withStore { store, _, _ in
            let id = try hookTicket(store, tab: "tab-w", handle: "term_w")
            _ = try hookTicket(store, tab: "tab-u", handle: "term_u", session: "s2")
            let snapshot = OrcaSnapshot(
                agents: [agent("tab-w"), agent("tab-u")], terminals: [terminal("tab-w", handle: "term_w"), terminal("tab-u", handle: "term_u")])
            let summary = try OrcaSync(store: store).apply(
                snapshot, workers: WorkerFetch(workers: [.init(handle: "term_w", runId: "run_1")], runsScanned: 1), now: now)
            #expect(summary.workersIgnored == 1 && summary.created == 0)
            #expect(summary.workerRefresh == WorkerRefreshReport(runs: 1, handles: 1, error: nil))
            #expect(try store.listTickets().map(\.id) != [id] && store.listTickets().count == 1)
            #expect(try store.location(byExternalKey: "orca-tab:tab-w") == nil && store.location(byExternalKey: "claude:s1") == nil)
            let ignored = try store.ignoredSessions()
            #expect(ignored.map(\.externalKey) == ["claude:s1"] && ignored[0].reason == OrcaWorker.handleReason)

            // 그 세션의 이후 훅 이벤트는 티켓을 되살리지 않는다.
            let stop = try Reconciler(store: store, projectResolver: NoProject()).apply(
                event: sessionEvent(.stop), env: OrcaEnv(terminalHandle: "term_w", tabId: "tab-w"), now: now)
            #expect(try stop == nil && store.listTickets().count == 1)
        }
    }

    @Test func aTouchedTicketOnAWorkerTerminalIsKeptAndMergedAsUsual() throws {
        try withStore { store, _, _ in
            let id = try hookTicket(store, tab: "tab-w", handle: "term_w")
            try store.patchTicket(id: id, TicketPatch(nextAction: .some("review it")))
            let summary = try OrcaSync(store: store).apply(
                OrcaSnapshot(agents: [agent("tab-w")], terminals: [terminal("tab-w", handle: "term_w")]),
                workers: WorkerFetch(workers: [.init(handle: "term_w", runId: "run_1")], runsScanned: 1), now: now)
            #expect(summary.workersIgnored == 0)
            #expect(try store.getTicket(id: id).title == "Fix login" && store.ignoredSessions().isEmpty)
        }
    }

    @Test func aFailedWorkerRefreshNeverFailsTheSyncAndIsReportedInTheSummary() throws {
        try withStore { store, _, _ in
            let snapshot = OrcaSnapshot(agents: [agent("tab-u")], terminals: [terminal("tab-u", handle: "term_u")])
            let summary = try OrcaSync(store: store).apply(snapshot, workers: WorkerFetch(error: "boom"), now: now)
            #expect(summary.created == 1 && summary.workerRefresh == WorkerRefreshReport(runs: 0, handles: 0, error: "boom"))
            // 조회하지 않은 sync는 workerRefresh가 nil이다.
            #expect(try OrcaSync(store: store).apply(snapshot, now: now).workerRefresh == nil)
        }
    }

    @Test func previewReportsTheSameSummaryAndRecordsNoHandlesOrTimestamps() throws {
        try withStore { store, _, _ in
            let id = try hookTicket(store, tab: "tab-w", handle: "term_w")
            let snapshot = OrcaSnapshot(agents: [agent("tab-w")], terminals: [terminal("tab-w", handle: "term_w")])
            let workers = WorkerFetch(workers: [.init(handle: "term_w", runId: "run_1")], runsScanned: 1)
            let preview = try OrcaSync(store: store).preview(snapshot, workers: workers, now: now)
            #expect(preview.workersIgnored == 1)
            #expect(try store.getTicket(id: id).id == id && store.orcaWorkerHandles().isEmpty && store.ignoredSessions().isEmpty)
            #expect(try store.meta(OrcaWorkers.attemptKey) == nil)
            let real = try OrcaSync(store: store).apply(snapshot, workers: workers, now: now)
            #expect(real == preview)
        }
    }
}
