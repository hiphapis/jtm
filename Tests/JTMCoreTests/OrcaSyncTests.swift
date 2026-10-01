import Foundation
import Testing
@testable import JTMCore

// 실제 Orca 출력(`orca worktree ps --json`, `orca terminal list --json`)을 이 기기에서 한 번 캡처해 프롬프트/미리보기/
// 제목/경로/ID를 가짜 값으로 바꾼 픽스처: Tests/Fixtures/orca-worktree-ps.json, orca-terminal-list.json.

private func fixtureData(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
    return try Data(contentsOf: url)
}

private func fixtureSnapshot() throws -> OrcaSnapshot {
    try OrcaSnapshot.decode(worktreePs: fixtureData("orca-worktree-ps.json"), terminalList: fixtureData("orca-terminal-list.json"))
}

/// 픽스처 캡처 직후의 시각(가장 최근 에이전트 `updatedAt`보다 조금 뒤).
private let fixtureNow = Date(timeIntervalSince1970: 1_790_743_000)

// MARK: 합성 스냅샷 헬퍼

private let base = Date(timeIntervalSince1970: 1_800_000_000)
private let wtId = "wt-uuid::/Users/me/Work/app-wt"

private func agent(
    _ tab: String, leaf: String = "leaf-1", state: String? = "working", type: String? = "claude",
    prompt: String? = nil, updated: Date? = base, path: String? = "/Users/me/Work/app-wt"
) -> OrcaSnapshot.Agent {
    .init(paneKey: "\(tab):\(leaf)", state: state, agentType: type, prompt: prompt, updatedAt: updated,
          worktreeId: wtId, worktreePath: path)
}

private func terminal(
    _ tab: String?, handle: String = "term_1", leaf: String? = "leaf-1", title: String? = "✳ Fix login", pty: String? = "pty-1",
    orphaned: Bool = false
) -> OrcaSnapshot.Terminal {
    .init(handle: handle, ptyId: pty, tabId: tab, leafId: leaf, title: title, orphaned: orphaned,
          worktreeId: wtId, worktreePath: "/Users/me/Work/app-wt")
}

private func snapshot(
    _ agents: [OrcaSnapshot.Agent] = [], _ terminals: [OrcaSnapshot.Terminal] = [], truncated: Bool = false,
    droppedElements: Int = 0
) -> OrcaSnapshot {
    OrcaSnapshot(agents: agents, terminals: terminals, truncated: truncated, droppedElements: droppedElements)
}

private func orcaLocation(_ store: Store, _ tab: String) throws -> Location {
    try #require(try store.location(byExternalKey: "orca-tab:\(tab)"))
}

private func orcaTerminal(_ location: Location) throws -> Locator.OrcaTerminal {
    guard case .orcaTerminal(let terminal) = location.locator else { throw StoreError.corrupt("not orca_terminal") }
    return terminal
}

@Suite struct OrcaSnapshotTests {
    @Test func decodesTheRealCapture() throws {
        let snapshot = try fixtureSnapshot()
        #expect(snapshot.agents.count == 11 && snapshot.terminals.count == 19 && !snapshot.truncated)
        #expect(snapshot.agents.filter { $0.state == "working" }.count == 2)
        #expect(snapshot.terminals.filter(\.orphaned).count == 12)
        let first = try #require(snapshot.agents.first)
        #expect(first.tabId.count == 36 && first.leafId?.count == 36 && first.agentType == "claude")
        #expect(first.worktreePath?.hasPrefix("/Users/me/Work/") == true)
        #expect(first.updatedAt == Date(timeIntervalSince1970: 1_790_742_913.029))
        // 떨어진 터미널은 임시 `pty:` tabId이고 제목이 없다.
        let orphan = try #require(snapshot.terminals.first { $0.orphaned })
        #expect(orphan.tabId?.hasPrefix("pty:") == true && orphan.title == nil)
    }

    @Test func toleratesUnknownFieldsMissingOptionalsAndBrokenElements() throws {
        let ps = """
        {"ok":true,"result":{"worktrees":[
          {"worktreeId":"w","path":"/p","future":{"x":1},"agents":[
            {"paneKey":"t1:l1","state":"working","updatedAt":1800000000000,"newField":[1,2]},
            {"paneKey":"t2:l2"},
            {"state":"done"},
            {"paneKey":42},
            "garbage"]},
          {"agents":"not a list"},
          17
        ],"truncated":true}}
        """
        let list = """
        {"ok":true,"result":{"terminals":[{"handle":"term_a","extra":1},{"tabId":"no-handle"},{"handle":"term_b","tabId":"t1","title":7,"orphaned":"yes"}]}}
        """
        let snapshot = try OrcaSnapshot.decode(worktreePs: Data(ps.utf8), terminalList: Data(list.utf8))
        #expect(snapshot.agents.map(\.paneKey) == ["t1:l1", "t2:l2"])
        #expect(snapshot.agents[0].updatedAt == Date(timeIntervalSince1970: 1_800_000_000) && snapshot.agents[1].updatedAt == nil)
        #expect(snapshot.agents[0].worktreePath == "/p")
        #expect(snapshot.terminals.map(\.handle) == ["term_a", "term_b"])
        #expect(snapshot.terminals[1].title == nil && snapshot.terminals[1].orphaned == false)
        #expect(snapshot.truncated)
    }

    @Test func truncatedOnEitherSideCounts() throws {
        let ps = #"{"ok":true,"result":{"worktrees":[]}}"#
        let list = #"{"ok":true,"result":{"terminals":[],"truncated":true}}"#
        #expect(try OrcaSnapshot.decode(worktreePs: Data(ps.utf8), terminalList: Data(list.utf8)).truncated)
    }

    @Test func rejectsEnvelopeErrorsAndGarbage() {
        let good = Data(#"{"ok":true,"result":{"worktrees":[],"terminals":[]}}"#.utf8)
        #expect(throws: SyncError.self) { try OrcaSnapshot.decode(worktreePs: Data("not json".utf8), terminalList: good) }
        #expect(throws: SyncError.self) { try OrcaSnapshot.decode(worktreePs: good, terminalList: Data(#"{"ok":false,"error":{"message":"boom"}}"#.utf8)) }
        #expect(throws: SyncError.self) { try OrcaSnapshot.decode(worktreePs: Data(#"{"ok":true}"#.utf8), terminalList: good) }
    }

    @Test func fetchRunsOnlyTheTwoReadOnlyCommandsWithTimeouts() throws {
        let runner = FakeRunner()
        runner.on(OrcaSnapshot.psArgv(orca), CommandResult(exitCode: 0, stdout: String(decoding: try fixtureData("orca-worktree-ps.json"), as: UTF8.self)))
        runner.on(OrcaSnapshot.terminalListArgv(orca), CommandResult(exitCode: 0, stdout: String(decoding: try fixtureData("orca-terminal-list.json"), as: UTF8.self)))
        let snapshot = try OrcaSnapshot.fetch(runner: runner, orca: orca)
        #expect(snapshot.agents.count == 11)
        #expect(runner.argvs == [
            [orca, "worktree", "ps", "--json", "--limit", "500"],
            [orca, "terminal", "list", "--json", "--limit", "500"],
        ])
        #expect(runner.calls.allSatisfy { $0.timeout > 0 && $0.stdin == nil })
    }

    @Test func fetchAppliesTheGivenTimeoutToEachCommandAndTwentySecondsByDefault() throws {
        for (timeout, expected) in [(nil, OrcaSnapshot.commandTimeout), (8, 8)] as [(TimeInterval?, TimeInterval)] {
            let runner = FakeRunner()
            runner.on(OrcaSnapshot.psArgv(orca), CommandResult(exitCode: 0, stdout: String(decoding: try fixtureData("orca-worktree-ps.json"), as: UTF8.self)))
            runner.on(OrcaSnapshot.terminalListArgv(orca), CommandResult(exitCode: 0, stdout: String(decoding: try fixtureData("orca-terminal-list.json"), as: UTF8.self)))
            if let timeout { _ = try OrcaSnapshot.fetch(runner: runner, orca: orca, timeout: timeout) } else { _ = try OrcaSnapshot.fetch(runner: runner, orca: orca) }
            #expect(runner.calls.map(\.timeout) == [expected, expected])
        }
        #expect(OrcaSnapshot.commandTimeout == 20)
    }

    @Test func fetchFailureAndTimeoutThrowWithTheCommandInTheMessage() {
        for failure in [orcaNotReady, CommandResult(exitCode: 124, stderr: "timed out after 20s"), CommandResult(exitCode: 127, stderr: "no such file")] {
            let runner = FakeRunner()
            runner.on([orca, "worktree", "ps"], failure)
            #expect(throws: SyncError.self) { try OrcaSnapshot.fetch(runner: runner, orca: orca) }
            do { _ = try OrcaSnapshot.fetch(runner: runner, orca: orca) } catch {
                #expect("\(error)".contains("orca worktree ps"))
            }
        }
    }
}

@Suite struct OrcaSyncTests {
    private func withSync(_ body: (OrcaSync, Store, TestClock) throws -> Void) throws {
        try withStore { store, clock, _ in try body(OrcaSync(store: store), store, clock) }
    }

    // MARK: 실측 픽스처

    @Test func realCaptureCreatesInboxTicketsOnlyForAgentsWithATerminalAndIsIdempotent() throws {
        try withSync { sync, store, clock in
            let snapshot = try fixtureSnapshot()
            let first = try sync.apply(snapshot, now: fixtureNow)
            #expect(first.created == 4 && first.skipped == 7 && first.updated == 0 && first.stale == 0 && first.gone == 0)
            let tickets = try store.listTickets()
            #expect(tickets.count == 4 && tickets.allSatisfy { $0.status == .inbox && !$0.pinnedTitle })
            #expect(tickets.map(\.title).sorted().allSatisfy { $0.hasPrefix("Synthetic session title") })
            #expect(tickets.allSatisfy { $0.project?.hasPrefix("project-") == true })
            for ticket in tickets {
                let location = try #require(try store.locations(ticketId: ticket.id).first)
                #expect(location.source == .orcaSync && location.externalKey?.hasPrefix("orca-tab:") == true)
                let terminal = try orcaTerminal(location)
                #expect(terminal.terminalHandle.hasPrefix("term_") && terminal.tabId != nil && terminal.worktreeId?.contains("::") == true)
            }

            clock.advance(60)
            let second = try sync.apply(snapshot, now: fixtureNow.addingTimeInterval(60))
            #expect(second.created == 0 && second.updated == 0 && second.stale == 0 && second.gone == 0 && second.skipped == 7)
            #expect(try store.listTickets().count == 4)
        }
    }

    @Test func previewReportsTheSameSummaryAndWritesNothing() throws {
        try withSync { sync, store, _ in
            let snapshot = try fixtureSnapshot()
            let preview = try sync.preview(snapshot, now: fixtureNow)
            #expect(preview.created == 4)
            #expect(try store.listTickets().isEmpty)
            #expect(try store.locations(externalKeyPrefix: "orca-tab:").isEmpty)
            let real = try sync.apply(snapshot, now: fixtureNow)
            #expect(real == preview.withIDs(of: real))
        }
    }

    // MARK: 생성

    @Test func newAgentGetsAnInboxTicketWithTerminalFieldsAndCleanTitle() throws {
        try withSync { sync, store, clock in
            let updated = base.addingTimeInterval(-3600)
            let summary = try sync.apply(snapshot([agent("tab-1", updated: updated)], [terminal("tab-1")]), now: base)
            #expect(summary.created == 1)
            let ticket = try store.getTicket(id: summary.createdTicketIds[0])
            #expect(ticket.title == "Fix login" && ticket.status == .inbox && !ticket.pinnedTitle)
            #expect(ticket.project == "app-wt" && ticket.lastActivityAt == updated)
            let location = try orcaLocation(store, "tab-1")
            #expect(location.ticketId == ticket.id && location.source == .orcaSync)
            #expect(try orcaTerminal(location) == .init(
                terminalHandle: "term_1", worktreeId: wtId, tabId: "tab-1", ptyId: "pty-1", titleHint: "Fix login"))
        }
    }

    @Test func titleFallsBackToThePromptWhenTheTerminalTitleIsMissingOrAShellPath() throws {
        try withSync { sync, store, _ in
            let long = String(repeating: "p", count: 80)
            for (index, title) in [nil, "~/Work/app", "..-task-manager", "/usr/local", "  ✳  ", ""].enumerated() {
                let tab = "tab-\(index)"
                let summary = try sync.apply(
                    snapshot([agent(tab, prompt: "  first\\n line \(long)")], [terminal(tab, handle: "term_\(index)", title: title)]), now: base)
                let ticket = try store.getTicket(id: summary.createdTicketIds[0])
                #expect(ticket.title.count == 60 && ticket.title.hasPrefix("first\\n line p"), "\(String(describing: title))")
            }
        }
    }

    @Test func titleFallsBackToAnAgentPlaceholderWhenThereIsNothingElse() throws {
        try withSync { sync, store, _ in
            let summary = try sync.apply(snapshot([agent("t", type: "codex", prompt: "")], [terminal("t", title: nil)]), now: base)
            #expect(try store.getTicket(id: summary.createdTicketIds[0]).title == "codex session")
        }
    }

    @Test func agentWithoutATerminalIsSkippedButLeafIdIsASecondaryKey() throws {
        try withSync { sync, store, _ in
            let skipped = try sync.apply(snapshot([agent("tab-x")], [terminal("other-tab", leaf: "other-leaf")]), now: base)
            #expect(skipped.created == 0 && skipped.skipped == 1 && skipped.gone == 0)
            #expect(try store.listTickets().isEmpty)

            // tabId는 안 맞지만 leafId가 같은 터미널이 있으면 그 handle을 쓴다(키는 paneKey의 tabId).
            let byLeaf = try sync.apply(snapshot([agent("tab-x", leaf: "leaf-7")], [terminal("renamed", handle: "term_7", leaf: "leaf-7")]), now: base)
            #expect(byLeaf.created == 1 && byLeaf.skipped == 0)
            let location = try orcaLocation(store, "tab-x")
            let locator = try orcaTerminal(location)
            #expect(locator.terminalHandle == "term_7" && locator.tabId == "tab-x")
        }
    }

    @Test func splitPanesOfOneTabCreateOneTicketFromTheMostRecentAgent() throws {
        try withSync { sync, store, _ in
            let older = agent("tab-1", leaf: "a", prompt: "older", updated: base.addingTimeInterval(-100))
            let newer = agent("tab-1", leaf: "b", prompt: "newer", updated: base)
            let summary = try sync.apply(
                snapshot([older, newer], [terminal("tab-1", leaf: "a", title: nil), terminal("tab-1", handle: "term_b", leaf: "b", title: nil)]), now: base)
            #expect(summary.created == 1)
            #expect(try store.getTicket(id: summary.createdTicketIds[0]).title == "newer")
            #expect(try orcaTerminal(orcaLocation(store, "tab-1")).terminalHandle == "term_b")
        }
    }

    @Test func orphanedTerminalsWithoutAnAgentMatchAreNeverTurnedIntoTickets() throws {
        try withSync { sync, store, _ in
            let summary = try sync.apply(snapshot([], [terminal("pty:x", title: nil, orphaned: true), terminal("shell-tab", title: "~/Work")]), now: base)
            #expect(summary.created == 0 && summary.skipped == 0)
            #expect(try store.listTickets().isEmpty)
        }
    }

    // MARK: 기존 티켓 병합

    private func hookTicket(_ store: Store, tab: String = "tab-1", handle: String = "term_old") throws -> Int64 {
        let outcome = try Reconciler(store: store, projectResolver: NoProjects()).apply(
            event: AgentEvent(agent: .claude, kind: .sessionStart, sessionId: "s1", cwd: "/w/repo"),
            env: OrcaEnv(terminalHandle: handle, tabId: tab, worktreeId: nil), now: base)
        return try #require(outcome).ticketId
    }

    @Test func existingHookTicketIsMatchedNotDuplicatedAndItsLocatorIsFilledIn() throws {
        try withSync { sync, store, _ in
            let id = try hookTicket(store)
            let summary = try sync.apply(snapshot([agent("tab-1", state: "done")], [terminal("tab-1", handle: "term_new")]), now: base)
            #expect(summary.created == 0 && summary.updated == 1)
            #expect(try store.listTickets().count == 1)
            let location = try orcaLocation(store, "tab-1")
            #expect(location.ticketId == id && location.source == .hook)  // 최초 source 유지
            #expect(try orcaTerminal(location) == .init(
                terminalHandle: "term_new", worktreeId: wtId, tabId: "tab-1", ptyId: "pty-1", titleHint: "Fix login"))
            let ticket = try store.getTicket(id: id)
            #expect(ticket.title == "Fix login" && ticket.project == "repo" && ticket.status == .active)  // 프로젝트는 훅이 이미 채움
        }
    }

    /// 같은 탭에 터미널이 둘(분할 pane)이어도, 훅이 기록한 handle이 스냅샷에 있으면 그 터미널을 쓴다(에이전트 leaf가 다른 pane을 가리켜도).
    @Test func theStoredHandleWinsOverOtherTerminalsOfTheSameTab() throws {
        try withSync { sync, store, _ in
            let id = try hookTicket(store, handle: "term_mine")
            let mine = terminal("tab-1", handle: "term_mine", leaf: "leaf-2", title: "✳ Mine", pty: "pty-mine")
            let other = terminal("tab-1", handle: "term_other", leaf: "leaf-1", title: "✳ Other", pty: "pty-other")
            let summary = try sync.apply(snapshot([agent("tab-1", leaf: "leaf-1", state: "done")], [other, mine]), now: base)
            #expect(summary.created == 0)
            let located = try orcaTerminal(orcaLocation(store, "tab-1"))
            #expect(located.terminalHandle == "term_mine" && located.ptyId == "pty-mine" && located.titleHint == "Mine")
            #expect(try store.getTicket(id: id).title == "Mine")
        }
    }

    /// 저장된 handle이 목록에 없을 때만 tabId/leafId로 찾는다.
    @Test func withoutTheStoredHandleTheTabAndLeafDecide() throws {
        try withSync { sync, store, _ in
            _ = try hookTicket(store, handle: "term_gone")
            let mine = terminal("tab-1", handle: "term_a", leaf: "leaf-2", title: "✳ A", pty: "pty-a")
            let other = terminal("tab-1", handle: "term_b", leaf: "leaf-1", title: "✳ B", pty: "pty-b")
            try sync.apply(snapshot([agent("tab-1", leaf: "leaf-1", state: "done")], [mine, other]), now: base)
            #expect(try orcaTerminal(orcaLocation(store, "tab-1")).terminalHandle == "term_b")
        }
    }

    @Test func pinnedTitleIsUntouchedAndAutoTitleIsOnlyWrittenWhenItChanges() throws {
        try withSync { sync, store, clock in
            let id = try hookTicket(store)
            try store.patchTicket(id: id, TicketPatch(title: "Mine", pinnedTitle: true))
            let pinned = try sync.apply(snapshot([agent("tab-1")], [terminal("tab-1")]), now: base)
            #expect(try store.getTicket(id: id).title == "Mine" && pinned.updated == 1)  // locator만 갱신

            try store.patchTicket(id: id, TicketPatch(pinnedTitle: false))
            clock.advance(10)
            #expect(try sync.apply(snapshot([agent("tab-1")], [terminal("tab-1")]), now: base).updated == 1)
            #expect(try store.getTicket(id: id).title == "Fix login")
            let updatedAt = try store.getTicket(id: id).updatedAt
            clock.advance(10)
            #expect(try sync.apply(snapshot([agent("tab-1")], [terminal("tab-1")]), now: base).updated == 0)
            #expect(try store.getTicket(id: id).updatedAt == updatedAt)
        }
    }

    @Test func projectIsFilledFromTheWorktreePathOnlyWhenNil() throws {
        try withSync { sync, store, _ in
            let id = try hookTicket(store)
            try store.patchTicket(id: id, TicketPatch(project: .some(nil)))
            try sync.apply(snapshot([agent("tab-1")], [terminal("tab-1")]), now: base)
            #expect(try store.getTicket(id: id).project == "app-wt")
            try store.patchTicket(id: id, TicketPatch(project: .some("mine")))
            try sync.apply(snapshot([agent("tab-1")], [terminal("tab-1")]), now: base)
            #expect(try store.getTicket(id: id).project == "mine")
        }
    }

    @Test func hookDrivenStatusIsNeverOverwrittenByOrcaState() throws {
        try withSync { sync, store, _ in
            let id = try hookTicket(store)
            try Reconciler(store: store, projectResolver: NoProjects()).apply(
                event: AgentEvent(agent: .claude, kind: .permissionRequest, sessionId: "s1"), env: nil, now: base)
            for state in ["done", "working", "idle", "error", nil] {
                try sync.apply(snapshot([agent("tab-1", state: state)], [terminal("tab-1")]), now: base)
                let ticket = try store.getTicket(id: id)
                #expect(ticket.status == .waiting && ticket.waitingReason == .permission, "\(String(describing: state))")
            }
        }
    }

    @Test func doneTicketsKeepTheirStatusAndTitleRulesStillApply() throws {
        try withSync { sync, store, _ in
            let id = try hookTicket(store)
            try store.patchTicket(id: id, TicketPatch(status: .done))
            let summary = try sync.apply(snapshot([agent("tab-1", updated: base.addingTimeInterval(-7200))], [terminal("tab-1")]), now: base)
            let status = try store.getTicket(id: id).status
            #expect(summary.stale == 0 && status == .done)
        }
    }

    // MARK: 멈춤 감지

    /// 훅 활동이 오래된 티켓(base 시각에 마지막 활동)을 만들고, 2시간 뒤(`late`)의 시각을 돌려준다.
    private func staleCandidate(_ store: Store, _ clock: TestClock) throws -> (id: Int64, late: Date) {
        let id = try hookTicket(store)
        clock.advance(7200)
        return (id, clock.current)
    }

    @Test func activeTicketWithAWorkingAgentIdleForOverTenMinutesBecomesWaitingStale() throws {
        try withSync { sync, store, clock in
            let (id, late) = try staleCandidate(store, clock)
            let activity = try store.getTicket(id: id).lastActivityAt
            let summary = try sync.apply(
                snapshot([agent("tab-1", state: "working", updated: late.addingTimeInterval(-601))], [terminal("tab-1")]), now: late)
            #expect(summary.stale == 1 && summary.staleTicketIds == [id])
            let ticket = try store.getTicket(id: id)
            #expect(ticket.status == .waiting && ticket.waitingReason == .stale)
            #expect(ticket.lastActivityAt == activity)  // 멈춤 표시는 에이전트 활동이 아니다

            // 다음 sync에서는 이미 waiting이라 다시 세지 않는다.
            #expect(try sync.apply(snapshot([agent("tab-1", state: "working", updated: late.addingTimeInterval(-900))], [terminal("tab-1")]), now: late).stale == 0)
        }
    }

    @Test(arguments: [
        ("working", 599.0, TicketStatus.active),  // 10분 미만
        ("done", 7200.0, .active),                 // 에이전트가 working이 아님
        ("working", 600.0, .active),               // 정확히 10분은 "넘게"가 아니다
        ("working", 601.0, .waiting),              // 10분을 넘으면 멈춤
    ])
    func staleBoundaryDependsOnlyOnTheAgentWhenHookActivityIsOld(state: String, idle: TimeInterval, expected: TicketStatus) throws {
        try withSync { sync, store, clock in
            let (id, late) = try staleCandidate(store, clock)
            let summary = try sync.apply(snapshot([agent("tab-1", state: state, updated: late.addingTimeInterval(-idle))], [terminal("tab-1")]), now: late)
            let status = try store.getTicket(id: id).status
            #expect(summary.stale == (expected == .waiting ? 1 : 0) && status == expected)
        }
    }

    /// 리뷰 재현 F: 훅이 방금 티켓을 active로 만들었는데(`last_activity_at`은 방금) Orca 에이전트는 working인 채 38분 전에 멈춰 있다.
    /// 훅 활동이 더 최근이므로 멈춤이 아니다.
    @Test func recentHookActivityKeepsATicketActiveEvenIfOrcaStateIsOld() throws {
        try withSync { sync, store, clock in
            let (id, late) = try staleCandidate(store, clock)
            clock.advance(0)
            try store.touchActivity(id: id, at: late.addingTimeInterval(-1))  // 1초 전에 훅이 활동을 기록했다
            let summary = try sync.apply(
                snapshot([agent("tab-1", state: "working", updated: late.addingTimeInterval(-38 * 60))], [terminal("tab-1")]), now: late)
            let ticket = try store.getTicket(id: id)
            #expect(summary.stale == 0 && summary.staleTicketIds.isEmpty)
            #expect(ticket.status == .active && ticket.waitingReason == nil)

            // 그 뒤 훅 활동도 10분 넘게 없으면 그때는 멈춤이다.
            let muchLater = late.addingTimeInterval(601)
            let again = try sync.apply(
                snapshot([agent("tab-1", state: "working", updated: late.addingTimeInterval(-38 * 60))], [terminal("tab-1")]), now: muchLater)
            #expect(again.stale == 1)
        }
    }

    /// 훅 활동이 Orca `updatedAt`보다 오래됐으면 기존처럼 `updatedAt` 기준이다(둘 중 더 최근 것).
    @Test func theMoreRecentOfHookAndOrcaActivityDecides() throws {
        try withSync { sync, store, clock in
            let (id, late) = try staleCandidate(store, clock)
            let summary = try sync.apply(
                snapshot([agent("tab-1", state: "working", updated: late.addingTimeInterval(-300))], [terminal("tab-1")]), now: late)
            #expect(summary.stale == 0)
            #expect(try store.getTicket(id: id).status == .active)
        }
    }

    @Test func onlyActiveTicketsGoStaleNotWaitingOrInbox() throws {
        try withSync { sync, store, _ in
            let old = base.addingTimeInterval(-3600)
            let id = try hookTicket(store)
            try store.patchTicket(id: id, TicketPatch(status: .waiting, waitingReason: .some(.turnEnd)))
            #expect(try sync.apply(snapshot([agent("tab-1", updated: old)], [terminal("tab-1")]), now: base).stale == 0)
            #expect(try store.getTicket(id: id).waitingReason == .turnEnd)
            // 폴러가 방금 만든 inbox 티켓도 멈춤 대상이 아니다.
            let created = try sync.apply(snapshot([agent("tab-2", updated: old)], [terminal("tab-2", handle: "term_2")]), now: base)
            #expect(created.created == 1 && created.stale == 0)
            #expect(try store.getTicket(id: created.createdTicketIds[0]).status == .inbox)
        }
    }

    // MARK: 사라진 탭

    @Test func tabAbsentInTwoConsecutiveSyncsGetsGoneAtAndAKeptTicketStatusIsUntouched() throws {
        try withSync { sync, store, _ in
            let id = try hookTicket(store)
            try store.setKept(id: id, true)  // 유지(⭐)가 아니면 사라진 탭은 자동 완료다(CleanupTests)
            let before = try store.getTicket(id: id)
            let first = try sync.apply(snapshot([], [terminal("other", handle: "term_other")]), now: base)
            #expect(first.gone == 0)
            let afterFirst = try orcaLocation(store, "tab-1")
            #expect(afterFirst.goneAt == nil && afterFirst.missCount == 1)

            let second = try sync.apply(snapshot([], [terminal("other", handle: "term_other")]), now: base.addingTimeInterval(30))
            #expect(second.gone == 1)
            #expect(try orcaLocation(store, "tab-1").goneAt == base.addingTimeInterval(30))
            #expect(try store.getTicket(id: id).status == before.status)

            // 처음 사라진 시각을 유지하고 다시 세지 않는다.
            #expect(try sync.apply(snapshot([], [terminal("other", handle: "term_other")]), now: base.addingTimeInterval(500)).gone == 0)
            #expect(try orcaLocation(store, "tab-1").goneAt == base.addingTimeInterval(30))
        }
    }

    @Test func aSingleMissFollowedBySeeingTheTabAgainStartsOver() throws {
        try withSync { sync, store, _ in
            _ = try hookTicket(store)
            try sync.apply(snapshot([], [terminal("other", handle: "term_other")]), now: base)
            #expect(try orcaLocation(store, "tab-1").missCount == 1)
            try sync.apply(snapshot([agent("tab-1", state: "done")], [terminal("tab-1")]), now: base.addingTimeInterval(30))
            #expect(try orcaLocation(store, "tab-1").missCount == 0)
            // 다시 한 번 빠져도 아직 gone이 아니다(연속 2회가 아님).
            let summary = try sync.apply(snapshot([], [terminal("other", handle: "term_other")]), now: base.addingTimeInterval(60))
            let location = try orcaLocation(store, "tab-1")
            #expect(summary.gone == 0 && location.goneAt == nil)
        }
    }

    @Test func aHookEventForTheTabAlsoClearsTheMissCounter() throws {
        try withSync { sync, store, _ in
            _ = try hookTicket(store)
            try sync.apply(snapshot([], [terminal("other", handle: "term_other")]), now: base)
            #expect(try orcaLocation(store, "tab-1").missCount == 1)
            _ = try hookTicket(store)  // 같은 세션의 다음 훅 이벤트
            #expect(try orcaLocation(store, "tab-1").missCount == 0)
        }
    }

    /// 리뷰 재현 I: `ok:true`인데 워크트리도 터미널도 없는 응답(Orca 재시작 직후 등)은 어떤 탭도 gone으로 만들지 않는다.
    @Test func emptySnapshotNeverCountsAsMissing() throws {
        try withSync { sync, store, _ in
            _ = try hookTicket(store)
            for offset in 0..<4 {
                let summary = try sync.apply(snapshot(), now: base.addingTimeInterval(Double(offset) * 30))
                #expect(summary.gone == 0)
            }
            let location = try orcaLocation(store, "tab-1")
            #expect(location.goneAt == nil && location.missCount == 0)
        }
    }

    /// 원소를 디코딩하지 못해 버렸다면(스키마 변경) 남은 것만으로 "사라짐"을 판단하지 않는다.
    @Test func snapshotWithDroppedElementsNeverMarksGone() throws {
        try withSync { sync, store, _ in
            _ = try hookTicket(store)
            for offset in 0..<3 {
                let dropped = snapshot([], [terminal("other", handle: "term_other")], droppedElements: 1)
                #expect(try sync.apply(dropped, now: base.addingTimeInterval(Double(offset) * 30)).gone == 0)
            }
            let location = try orcaLocation(store, "tab-1")
            #expect(location.goneAt == nil && location.missCount == 0)
        }
    }

    @Test func decodeCountsElementsItHadToDrop() throws {
        let ps = """
        {"ok":true,"result":{"worktrees":[
          {"worktreeId":"w","path":"/p","agents":[{"paneKey":"t1:l1","state":"working"},{"state":"done"},42]},
          {"worktreeId":"w2","agents":"not a list"},
          17
        ]}}
        """
        let list = """
        {"ok":true,"result":{"terminals":[{"handle":"term_1","tabId":"t1"},{"handle":7},"junk"]}}
        """
        let decoded = try OrcaSnapshot.decode(worktreePs: Data(ps.utf8), terminalList: Data(list.utf8))
        #expect(decoded.agents.count == 1 && decoded.terminals.count == 1)
        // 못 읽은 에이전트 2(`{"state":"done"}`, `42`) + 배열이 아닌 agents 1 + 못 읽은 워크트리 1(`17`) + 못 읽은 터미널 2.
        #expect(decoded.droppedElements == 6)
        #expect(!decoded.canDetectGone)
        let clean = try fixtureSnapshot()
        #expect(clean.droppedElements == 0 && clean.canDetectGone)
        #expect(!OrcaSnapshot().canDetectGone)
    }

    @Test func reappearingTabClearsGoneAt() throws {
        try withSync { sync, store, _ in
            _ = try hookTicket(store)
            try sync.apply(snapshot([], [terminal("other", handle: "term_other")]), now: base)
            try sync.apply(snapshot([], [terminal("other", handle: "term_other")]), now: base.addingTimeInterval(30))
            #expect(try orcaLocation(store, "tab-1").goneAt == base.addingTimeInterval(30))

            // (a) 에이전트로 다시 보임
            let viaAgent = try sync.apply(snapshot([agent("tab-1", state: "done")], [terminal("tab-1")]), now: base.addingTimeInterval(60))
            let afterAgent = try orcaLocation(store, "tab-1")
            #expect(viaAgent.revived == 1 && afterAgent.goneAt == nil)

            // (b) 에이전트 없이 터미널(셸)로만 보임
            try sync.apply(snapshot([], [terminal("other", handle: "term_other")]), now: base.addingTimeInterval(120))
            try sync.apply(snapshot([], [terminal("other", handle: "term_other")]), now: base.addingTimeInterval(150))
            #expect(try orcaLocation(store, "tab-1").goneAt != nil)
            let viaShell = try sync.apply(snapshot([], [terminal("tab-1", title: "~/Work")]), now: base.addingTimeInterval(180))
            let afterShell = try orcaLocation(store, "tab-1")
            #expect(viaShell.revived == 1 && afterShell.goneAt == nil)
        }
    }

    @Test func orphanedTerminalMatchedByHandleIsNotGone() throws {
        try withSync { sync, store, _ in
            _ = try hookTicket(store, handle: "term_keep")
            // 재시작 직후: tabId가 `pty:` 임시값이고 제목이 없지만 handle은 그대로다.
            let orphan = terminal("pty:temp", handle: "term_keep", leaf: "pty:temp", title: nil, pty: "pty-9", orphaned: true)
            let summary = try sync.apply(snapshot([], [orphan]), now: base)
            #expect(summary.gone == 0)
            #expect(try sync.apply(snapshot([], [orphan]), now: base.addingTimeInterval(30)).gone == 0)
            let location = try orcaLocation(store, "tab-1")
            #expect(location.goneAt == nil)
            let locator = try orcaTerminal(location)
            #expect(locator.tabId == "tab-1" && locator.ptyId == "pty-9" && locator.terminalHandle == "term_keep")  // 임시 tabId는 쓰지 않는다
        }
    }

    @Test func agentStillListedKeepsItsTabAliveEvenWithoutATerminal() throws {
        try withSync { sync, store, _ in
            _ = try hookTicket(store)
            let summary = try sync.apply(snapshot([agent("tab-1", state: "done")], []), now: base)
            #expect(summary.gone == 0 && summary.skipped == 0)
            #expect(try sync.apply(snapshot([agent("tab-1", state: "done")], []), now: base.addingTimeInterval(30)).gone == 0)
            #expect(try orcaLocation(store, "tab-1").goneAt == nil)
        }
    }

    @Test func truncatedSnapshotNeverMarksAnythingGone() throws {
        try withSync { sync, store, _ in
            _ = try hookTicket(store)
            let summary = try sync.apply(snapshot([], [terminal("other", handle: "term_other")], truncated: true), now: base)
            #expect(summary.gone == 0 && summary.truncated)
            #expect(try sync.apply(snapshot([], [terminal("other", handle: "term_other")], truncated: true), now: base.addingTimeInterval(30)).gone == 0)
            #expect(try orcaLocation(store, "tab-1").goneAt == nil)
        }
    }

    @Test func locationsWithoutAnOrcaTabKeyAreIgnored() throws {
        try withSync { sync, store, _ in
            let ticket = try store.createTicket(title: "manual")
            let manual = try store.addLocation(
                ticketId: ticket.id, locator: .orcaTerminal(.init(terminalHandle: "term_manual")), source: .manual)
            let session = try store.addLocation(
                ticketId: ticket.id, locator: .claudeCode(.init(sessionId: "s", cwd: "/w")), source: .hook, externalKey: "claude:s")
            try sync.apply(snapshot(), now: base)
            #expect(try store.locations(ticketId: ticket.id).map(\.goneAt) == [nil, nil])
            _ = (manual, session)
        }
    }

    // MARK: 훅과의 조합

    @Test func aPollerTicketIsAdoptedByTheFirstSessionStartInsteadOfGettingADuplicate() throws {
        try withSync { sync, store, _ in
            let summary = try sync.apply(snapshot([agent("tab-1", type: "codex")], [terminal("tab-1")]), now: base)
            let outcome = try #require(try Reconciler(store: store, projectResolver: NoProjects()).apply(
                event: AgentEvent(agent: .codex, kind: .sessionStart, sessionId: "th-1", cwd: "/w"),
                env: OrcaEnv(terminalHandle: "term_1", tabId: "tab-1", worktreeId: wtId), now: base))
            #expect(outcome.ticketId == summary.createdTicketIds[0] && !outcome.created)
            #expect(try store.listTickets().count == 1)
        }
    }

    // MARK: 제목 정리

    @Test(arguments: [
        ("✳ Fix login", "Fix login"), ("◐ Fix login", "Fix login"), ("◑  Fix login ", "Fix login"),
        ("⠂ Working", "Working"), ("✳ #39 POST /v1/actions 배열 입력", "#39 POST /v1/actions 배열 입력"),
        ("Fix login", "Fix login"), ("✳ ● Two glyphs", "Two glyphs"), ("\"quoted\" title", "\"quoted\" title"),
        ("[main] title", "[main] title"),
    ])
    func cleanTitleStripsStatusGlyphs(raw: String, expected: String) {
        #expect(OrcaSync.cleanTitle(raw) == expected)
    }

    @Test(arguments: [nil, "", "   ", "✳", "✳ ◑", "~/Work/app", "~", "/usr/local/bin", "..-task-manager", "../apps/web", "  ~/x"] as [String?])
    func cleanTitleRejectsEmptyAndShellPathTitles(raw: String?) {
        #expect(OrcaSync.cleanTitle(raw) == nil)
    }
}

private struct NoProjects: ProjectResolver {
    func gitTopLevel(containing cwd: String) -> String? { nil }
}

private extension SyncSummary {
    /// 미리보기와 실제 실행의 요약을 비교할 때, 티켓 ID는 실행마다(롤백 때문에) 같을 수 있어 그대로 맞춘다.
    func withIDs(of other: SyncSummary) -> SyncSummary {
        var copy = self
        copy.createdTicketIds = other.createdTicketIds
        copy.staleTicketIds = other.staleTicketIds
        return copy
    }
}
