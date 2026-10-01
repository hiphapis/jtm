import Foundation
import Testing
@testable import JTMCore

private struct StubProjects: ProjectResolver {
    var root: String?
    func gitTopLevel(containing cwd: String) -> String? { root }
}

private let cwd = "/Users/me/Work/app"
private func orca(tab: String = "tab-1", handle: String = "term_1", worktree: String? = "wt-uuid::/Users/me/Work/app-wt") -> OrcaEnv {
    OrcaEnv(terminalHandle: handle, tabId: tab, worktreeId: worktree)
}

private func event(
    _ kind: AgentEventKind, _ session: String = "s1", agent: AgentType = .claude, cwd: String? = cwd, prompt: String? = nil
) -> AgentEvent {
    AgentEvent(agent: agent, kind: kind, sessionId: session, cwd: cwd, prompt: prompt)
}

/// 위치 키(정렬). 위치는 id 순으로 나오는데, 옮겨진 탭 위치는 원래 id를 유지하므로 순서가 아니라 집합으로 비교한다.
private func locationKeys(_ store: Store, _ ticketId: Int64) throws -> [String] {
    try store.locations(ticketId: ticketId).compactMap(\.externalKey).sorted()
}

private func withReconciler(
    root: String? = nil, _ body: (Reconciler, Store, TestClock) throws -> Void
) throws {
    try withStore { store, clock, _ in
        try body(Reconciler(store: store, projectResolver: StubProjects(root: root)), store, clock)
    }
}

@Suite struct ReconcilerTests {
    // MARK: get-or-create

    @Test func sessionStartCreatesActiveTicketWithPlaceholderTitleAndLocations() throws {
        try withReconciler { reconciler, store, clock in
            let outcome = try #require(try reconciler.apply(event: event(.sessionStart), env: orca(), now: clock.current))
            #expect(outcome.created)
            let ticket = try store.getTicket(id: outcome.ticketId)
            #expect(ticket.title == "claude session" && !ticket.pinnedTitle)
            #expect(ticket.status == .active && ticket.waitingReason == nil && ticket.endedAt == nil)
            let locations = try store.locations(ticketId: ticket.id)
            #expect(locations.compactMap(\.externalKey).sorted() == ["claude:s1", "orca-tab:tab-1"])
            #expect(locations[0].locator == .claudeCode(.init(sessionId: "s1", cwd: cwd)))
            #expect(locations[1].locator == .orcaTerminal(.init(terminalHandle: "term_1", worktreeId: "wt-uuid::/Users/me/Work/app-wt", tabId: "tab-1")))
            #expect(locations.allSatisfy { $0.source == .hook })
        }
    }

    @Test func codexLocationCarriesCwdAndUsesCodexKey() throws {
        try withReconciler { reconciler, store, clock in
            let outcome = try #require(try reconciler.apply(event: event(.sessionStart, "th-1", agent: .codex), env: nil, now: clock.current))
            let ticket = try store.getTicket(id: outcome.ticketId)
            #expect(ticket.title == "codex session")
            let location = try #require(try store.location(byExternalKey: "codex:th-1"))
            #expect(location.locator == .codexThread(.init(threadId: "th-1", cwd: cwd)))
        }
    }

    @Test func repeatedEventsForOneSessionKeepOneTicket() throws {
        try withReconciler { reconciler, store, clock in
            for kind in [AgentEventKind.sessionStart, .userPromptSubmit, .stop, .userPromptSubmit, .permissionRequest] {
                try reconciler.apply(event: event(kind, prompt: "hi"), env: orca(), now: clock.current)
            }
            #expect(try store.listTickets().count == 1)
        }
    }

    @Test func promptCreatesTheTicketWhenSessionStartWasMissed() throws {
        try withReconciler { reconciler, store, clock in
            let outcome = try #require(try reconciler.apply(
                event: event(.userPromptSubmit, prompt: "Fix the flaky test"), env: nil, now: clock.current))
            let ticket = try store.getTicket(id: outcome.ticketId)
            #expect(outcome.created && ticket.title == "Fix the flaky test" && ticket.status == .active)
        }
    }

    @Test func stopOrPermissionCanCreateTheTicketToo() throws {
        try withReconciler { reconciler, store, clock in
            let stopped = try #require(try reconciler.apply(event: event(.stop, "a"), env: nil, now: clock.current))
            let asked = try #require(try reconciler.apply(event: event(.permissionRequest, "b"), env: nil, now: clock.current))
            let a = try store.getTicket(id: stopped.ticketId), b = try store.getTicket(id: asked.ticketId)
            #expect(a.status == .waiting && a.waitingReason == .turnEnd && a.title == "claude session")
            #expect(b.status == .waiting && b.waitingReason == .permission)
        }
    }

    // MARK: status table

    @Test func statusAndWaitingReasonFollowTheEventTable() throws {
        try withReconciler { reconciler, store, clock in
            let id = try #require(try reconciler.apply(event: event(.sessionStart), env: nil, now: clock.current)).ticketId
            func state(after kind: AgentEventKind) throws -> (TicketStatus, WaitingReason?) {
                clock.advance(1)
                try reconciler.apply(event: event(kind, prompt: "p"), env: nil, now: clock.current)
                let ticket = try store.getTicket(id: id)
                return (ticket.status, ticket.waitingReason)
            }
            #expect(try state(after: .userPromptSubmit) == (.active, nil))
            #expect(try state(after: .stop) == (.waiting, .turnEnd))
            #expect(try state(after: .permissionRequest) == (.waiting, .permission))
            #expect(try state(after: .userPromptSubmit) == (.active, nil))
            #expect(try state(after: .stop) == (.waiting, .turnEnd))
            #expect(try state(after: .sessionStart) == (.active, nil))
        }
    }

    @Test func everyEventBumpsLastActivityAndNeverMovesItBackwards() throws {
        try withReconciler { reconciler, store, clock in
            let id = try #require(try reconciler.apply(event: event(.sessionStart), env: nil, now: clock.current)).ticketId
            clock.advance(100)
            try reconciler.apply(event: event(.stop), env: nil, now: clock.current)
            #expect(try store.getTicket(id: id).lastActivityAt == clock.current)
            try reconciler.apply(event: event(.stop), env: nil, now: clock.current.addingTimeInterval(-50))
            #expect(try store.getTicket(id: id).lastActivityAt == clock.current)
        }
    }

    @Test func doneTicketsAreNeverReopenedOnlyActivityAdvances() throws {
        try withReconciler { reconciler, store, clock in
            let id = try #require(try reconciler.apply(event: event(.sessionStart), env: nil, now: clock.current)).ticketId
            try store.patchTicket(id: id, TicketPatch(status: .done))
            clock.advance(500)
            for kind in [AgentEventKind.userPromptSubmit, .stop, .permissionRequest, .sessionStart, .sessionEnd, .stopFailure, .postToolUse] {
                try reconciler.apply(event: event(kind, prompt: "again"), env: nil, now: clock.current)
                let ticket = try store.getTicket(id: id)
                #expect(ticket.status == .done && ticket.waitingReason == nil && ticket.endedAt == nil, "\(kind)")
                #expect(ticket.lastActivityAt == clock.current, "\(kind)")
            }
        }
    }

    @Test func sessionEndOfAKeptTicketRecordsEndedAtKeepsStatusAndActivityRevivesIt() throws {
        try withReconciler { reconciler, store, clock in
            let id = try #require(try reconciler.apply(event: event(.stop), env: nil, now: clock.current)).ticketId
            try store.setKept(id: id, true)  // 유지(⭐) 티켓은 자동 완료를 받지 않는다
            clock.advance(30)
            try reconciler.apply(event: event(.sessionEnd), env: nil, now: clock.current)
            var ticket = try store.getTicket(id: id)
            #expect(ticket.status == .waiting && ticket.waitingReason == .turnEnd && ticket.endedAt == clock.current)

            clock.advance(30)  // 같은 세션을 다시 열었다
            try reconciler.apply(event: event(.sessionStart), env: nil, now: clock.current)
            ticket = try store.getTicket(id: id)
            #expect(ticket.status == .active && ticket.endedAt == nil)
        }
    }

    @Test func sessionEndOfAnUnkeptTicketMarksItDone() throws {
        try withReconciler { reconciler, store, clock in
            let id = try #require(try reconciler.apply(event: event(.stop), env: nil, now: clock.current)).ticketId
            clock.advance(30)
            try reconciler.apply(event: event(.sessionEnd), env: nil, now: clock.current)
            let ticket = try store.getTicket(id: id)
            #expect(ticket.status == .done && ticket.waitingReason == nil && ticket.endedAt == clock.current)
            #expect(ticket.lastActivityAt == clock.current && !ticket.kept)
        }
    }

    @Test func sessionEndForAnUnknownSessionCreatesNothing() throws {
        try withReconciler { reconciler, store, clock in
            let outcome = try reconciler.apply(event: event(.sessionEnd, "ghost"), env: orca(), now: clock.current)
            #expect(outcome == nil)
            #expect(try store.listTickets().isEmpty)
            #expect(try store.location(byExternalKey: "orca-tab:tab-1") == nil)
        }
    }

    // MARK: title

    @Test func firstPromptReplacesThePlaceholderAndLaterPromptsDoNot() throws {
        try withReconciler { reconciler, store, clock in
            let id = try #require(try reconciler.apply(event: event(.sessionStart), env: nil, now: clock.current)).ticketId
            try reconciler.apply(event: event(.userPromptSubmit, prompt: "  first\n\n  question  "), env: nil, now: clock.current)
            #expect(try store.getTicket(id: id).title == "first question")
            try reconciler.apply(event: event(.userPromptSubmit, prompt: "second question"), env: nil, now: clock.current)
            #expect(try store.getTicket(id: id).title == "first question")
        }
    }

    @Test func pinnedTitleIsNeverTouched() throws {
        try withReconciler { reconciler, store, clock in
            let id = try #require(try reconciler.apply(event: event(.sessionStart), env: nil, now: clock.current)).ticketId
            try store.patchTicket(id: id, TicketPatch(title: "claude session", pinnedTitle: true))  // 사용자가 (우연히 같은) 제목을 고정
            try reconciler.apply(event: event(.userPromptSubmit, prompt: "something else"), env: nil, now: clock.current)
            let ticket = try store.getTicket(id: id)
            #expect(ticket.title == "claude session" && ticket.pinnedTitle)
        }
    }

    @Test func aTitleSetByAnotherSourceSurvivesTheFirstPrompt() throws {
        try withReconciler { reconciler, store, clock in
            let id = try #require(try reconciler.apply(event: event(.sessionStart), env: nil, now: clock.current)).ticketId
            try store.autoUpdateTitle(id: id, title: "✳ terminal title")
            try reconciler.apply(event: event(.userPromptSubmit, prompt: "hello"), env: nil, now: clock.current)
            #expect(try store.getTicket(id: id).title == "✳ terminal title")
        }
    }

    @Test func promptTitleIsSingleLineTrimmedAndCappedAt60Characters() {
        #expect(Reconciler.title(fromPrompt: "a\tb\r\nc") == "a b c")
        #expect(Reconciler.title(fromPrompt: "   \n ") == nil)
        let long = String(repeating: "가", count: 100)
        #expect(Reconciler.title(fromPrompt: long) == String(repeating: "가", count: 60))
        // 60자에서 잘린 뒤 남은 끝 공백은 지운다.
        let padded = String(repeating: "x", count: 59) + " tail"
        #expect(Reconciler.title(fromPrompt: padded) == String(repeating: "x", count: 59))
    }

    @Test func blankPromptKeepsThePlaceholder() throws {
        try withReconciler { reconciler, store, clock in
            let id = try #require(try reconciler.apply(event: event(.userPromptSubmit, prompt: " \n "), env: nil, now: clock.current)).ticketId
            #expect(try store.getTicket(id: id).title == "claude session")
        }
    }

    // MARK: Orca tab

    @Test func sameTabNewSessionMovesTheTabLocationToTheNewestTicket() throws {
        try withReconciler { reconciler, store, clock in
            let first = try #require(try reconciler.apply(event: event(.sessionStart, "s1"), env: orca(), now: clock.current)).ticketId
            let second = try #require(try reconciler.apply(event: event(.sessionStart, "s2", agent: .codex), env: orca(), now: clock.current)).ticketId
            #expect(first != second)
            #expect(try locationKeys(store, first) == ["claude:s1"])
            #expect(try locationKeys(store, second) == ["codex:s2", "orca-tab:tab-1"])
            #expect(try store.listTickets().count == 2)

            // 이전 세션이 다시 살아나 이벤트를 보내면 탭은 그쪽으로 돌아간다(가장 최근 세션이 주인).
            try reconciler.apply(event: event(.userPromptSubmit, "s1", prompt: "back"), env: orca(), now: clock.current)
            #expect(try locationKeys(store, first) == ["claude:s1", "orca-tab:tab-1"])
            #expect(try locationKeys(store, second) == ["codex:s2"])
        }
    }

    /// 폴러가 탭만 보고 만든 inbox 티켓(세션 위치 없음)이 있는 탭에서 Codex의 첫 SessionStart가 오면, 새 티켓 없이 그 티켓에 세션이 붙는다.
    @Test func adoptsThePollerCreatedInboxTicketOnTheFirstSessionStart() throws {
        try withReconciler { reconciler, store, clock in
            let poller = try store.createTicket(title: "✳ terminal title", status: .inbox)
            let tab = try store.addLocation(
                ticketId: poller.id,
                locator: .orcaTerminal(.init(terminalHandle: "term_1", tabId: "tab-1", ptyId: "pty-9")),
                source: .orcaSync, externalKey: "orca-tab:tab-1")

            let outcome = try #require(try reconciler.apply(
                event: event(.sessionStart, "th-1", agent: .codex), env: orca(), now: clock.current))
            #expect(outcome.ticketId == poller.id && !outcome.created)
            #expect(try store.listTickets().count == 1)
            #expect(try locationKeys(store, poller.id) == ["codex:th-1", "orca-tab:tab-1"])
            let adopted = try store.getTicket(id: poller.id)
            #expect(adopted.status == .active && adopted.title == "✳ terminal title")
            #expect(try store.location(byExternalKey: "codex:th-1")?.locator == .codexThread(.init(threadId: "th-1", cwd: cwd)))
            // 폴러가 만든 탭 위치는 그대로 그 행이고, 폴러가 채운 값도 남는다.
            let keptTab = try #require(try store.location(byExternalKey: "orca-tab:tab-1"))
            #expect(keptTab.id == tab.id && keptTab.source == .orcaSync)
            guard case .orcaTerminal(let terminal) = keptTab.locator else { Issue.record("not orca_terminal"); return }
            #expect(terminal.ptyId == "pty-9")

            // 이후 같은 세션의 이벤트는 같은 티켓으로 간다.
            let next = try #require(try reconciler.apply(event: event(.stop, "th-1", agent: .codex), env: orca(), now: clock.current))
            #expect(next.ticketId == poller.id && !next.created)
            #expect(try store.listTickets().count == 1)
            #expect(try store.getTicket(id: poller.id).waitingReason == .turnEnd)
        }
    }

    /// 탭의 티켓에 이미 다른 세션이 있으면 입양하지 않는다: 새 티켓을 만들고 탭 위치를 옮기는 기존 규칙이 그대로다.
    @Test func doesNotAdoptATabTicketThatAlreadyHasAnotherSession() throws {
        try withReconciler { reconciler, store, clock in
            let first = try #require(try reconciler.apply(event: event(.sessionStart, "s1"), env: orca(), now: clock.current)).ticketId
            let second = try #require(try reconciler.apply(
                event: event(.sessionStart, "th-2", agent: .codex), env: orca(), now: clock.current))
            #expect(second.created && second.ticketId != first)
            #expect(try store.listTickets().count == 2)
            #expect(try locationKeys(store, first) == ["claude:s1"])
            #expect(try locationKeys(store, second.ticketId) == ["codex:th-2", "orca-tab:tab-1"])
        }
    }

    @Test func doesNotAdoptADoneTabTicket() throws {
        try withReconciler { reconciler, store, clock in
            let poller = try store.createTicket(title: "closed", status: .done)
            try store.addLocation(
                ticketId: poller.id, locator: .orcaTerminal(.init(terminalHandle: "term_1", tabId: "tab-1")),
                source: .orcaSync, externalKey: "orca-tab:tab-1")
            let outcome = try #require(try reconciler.apply(event: event(.sessionStart), env: orca(), now: clock.current))
            #expect(outcome.created && outcome.ticketId != poller.id)
            #expect(try store.getTicket(id: poller.id).status == .done)
            #expect(try locationKeys(store, poller.id).isEmpty)
            #expect(try locationKeys(store, outcome.ticketId) == ["claude:s1", "orca-tab:tab-1"])
        }
    }

    @Test func sessionEndDoesNotAdoptOrCreateAnything() throws {
        try withReconciler { reconciler, store, clock in
            let poller = try store.createTicket(title: "t", status: .inbox)
            try store.addLocation(
                ticketId: poller.id, locator: .orcaTerminal(.init(terminalHandle: "term_1", tabId: "tab-1")),
                source: .orcaSync, externalKey: "orca-tab:tab-1")
            let outcome = try reconciler.apply(event: event(.sessionEnd, "ghost"), env: orca(), now: clock.current)
            #expect(outcome == nil)
            #expect(try locationKeys(store, poller.id) == ["orca-tab:tab-1"])
        }
    }

    @Test func differentTabsStayOnTheirOwnTickets() throws {
        try withReconciler { reconciler, store, clock in
            let a = try #require(try reconciler.apply(event: event(.sessionStart, "s1"), env: orca(tab: "A"), now: clock.current)).ticketId
            let b = try #require(try reconciler.apply(event: event(.sessionStart, "s2"), env: orca(tab: "B"), now: clock.current)).ticketId
            #expect(try locationKeys(store, a) == ["claude:s1", "orca-tab:A"])
            #expect(try locationKeys(store, b) == ["claude:s2", "orca-tab:B"])
        }
    }

    @Test func orcaLocationIsSkippedWithoutHandleOrTabId() throws {
        try withReconciler { reconciler, store, clock in
            let noTab = try #require(try reconciler.apply(
                event: event(.sessionStart, "s1"), env: OrcaEnv(terminalHandle: "term_1", tabId: nil, worktreeId: nil), now: clock.current)).ticketId
            let noHandle = try #require(try reconciler.apply(
                event: event(.sessionStart, "s2"), env: OrcaEnv(terminalHandle: nil, tabId: "T", worktreeId: nil), now: clock.current)).ticketId
            #expect(try store.locations(ticketId: noTab).map(\.kind) == [.claudeCode])
            #expect(try store.locations(ticketId: noHandle).map(\.kind) == [.claudeCode])
        }
    }

    @Test func hookRefreshKeepsPollerFieldsOnTheTabLocation() throws {
        try withReconciler { reconciler, store, clock in
            let id = try #require(try reconciler.apply(event: event(.sessionStart), env: orca(), now: clock.current)).ticketId
            let tab = try #require(try store.location(byExternalKey: "orca-tab:tab-1"))
            try store.updateLocation(id: tab.id, locator: .orcaTerminal(.init(
                terminalHandle: "term_1", worktreeId: "wt-uuid::/Users/me/Work/app-wt", tabId: "tab-1", ptyId: "pty-9", titleHint: "my title")))
            try reconciler.apply(event: event(.stop), env: orca(), now: clock.current)
            guard case .orcaTerminal(let terminal) = try #require(try store.location(byExternalKey: "orca-tab:tab-1")).locator else {
                Issue.record("not an orca_terminal"); return
            }
            #expect(terminal.ptyId == "pty-9" && terminal.titleHint == "my title")
            #expect(try store.locations(ticketId: id).count == 2)

            // 핸들이 바뀌면(다른 터미널) 이전 ptyId는 버린다.
            try reconciler.apply(event: event(.stop), env: orca(handle: "term_2"), now: clock.current)
            guard case .orcaTerminal(let replaced) = try #require(try store.location(byExternalKey: "orca-tab:tab-1")).locator else { return }
            #expect(replaced.terminalHandle == "term_2" && replaced.ptyId == nil && replaced.titleHint == "my title")
        }
    }

    @Test func reappearingTabClearsGoneAt() throws {
        try withReconciler { reconciler, store, clock in
            try reconciler.apply(event: event(.sessionStart), env: orca(), now: clock.current)
            let tab = try #require(try store.location(byExternalKey: "orca-tab:tab-1"))
            try store.setLocationGone(id: tab.id, at: clock.current)
            try reconciler.apply(event: event(.stop), env: orca(), now: clock.current)
            #expect(try store.location(byExternalKey: "orca-tab:tab-1")?.goneAt == nil)
        }
    }

    // MARK: 탭 소유권 (S2)

    /// 같은 탭에서 A1 → B1 순서로 시작하면 탭은 B1이 가진다. 늦게 도착한 A1의 비활동 이벤트는 탭을 되찾아 가지 못한다(리뷰 재현 A).
    @Test func lateInactivityEventsFromAnOlderSessionDoNotStealTheTab() throws {
        try withReconciler { reconciler, store, clock in
            let a1 = try #require(try reconciler.apply(event: event(.sessionStart, "a1"), env: orca(), now: clock.current)).ticketId
            let b1 = try #require(try reconciler.apply(event: event(.sessionStart, "b1"), env: orca(), now: clock.current)).ticketId
            #expect(try locationKeys(store, b1) == ["claude:b1", "orca-tab:tab-1"])

            for kind in [AgentEventKind.sessionEnd, .stop, .permissionRequest, .stopFailure, .postToolUse] {
                clock.advance(1)
                try reconciler.apply(event: event(kind, "a1"), env: orca(), now: clock.current)
                #expect(try locationKeys(store, a1) == ["claude:a1"], "\(kind)")
                #expect(try locationKeys(store, b1) == ["claude:b1", "orca-tab:tab-1"], "\(kind)")
            }
            // 옛 세션이 정말 되살아나면(프롬프트) 탭은 다시 그쪽으로 간다.
            try reconciler.apply(event: event(.userPromptSubmit, "a1", prompt: "back"), env: orca(), now: clock.current)
            #expect(try locationKeys(store, a1) == ["claude:a1", "orca-tab:tab-1"])
        }
    }

    /// `/clear` 순서: 새 세션 SessionStart 뒤에 옛 세션 SessionEnd가 와도 탭은 새 티켓에 남는다(리뷰 재현 B).
    @Test func sessionEndOfTheReplacedSessionKeepsTheTabOnTheNewTicket() throws {
        try withReconciler { reconciler, store, clock in
            let old = try #require(try reconciler.apply(event: event(.sessionStart, "o1"), env: orca(), now: clock.current)).ticketId
            let new = try #require(try reconciler.apply(event: event(.sessionStart, "n1"), env: orca(), now: clock.current)).ticketId
            clock.advance(1)
            try reconciler.apply(event: event(.sessionEnd, "o1"), env: orca(), now: clock.current)
            #expect(try locationKeys(store, new) == ["claude:n1", "orca-tab:tab-1"])
            #expect(try locationKeys(store, old) == ["claude:o1"])
            #expect(try store.getTicket(id: old).endedAt == clock.current)
        }
    }

    @Test func sessionEndNeverCreatesOrRefreshesALocation() throws {
        try withReconciler { reconciler, store, clock in
            let id = try #require(try reconciler.apply(event: event(.sessionStart, "s1"), env: nil, now: clock.current)).ticketId
            try reconciler.apply(event: event(.sessionEnd, "s1"), env: orca(), now: clock.current)
            #expect(try locationKeys(store, id) == ["claude:s1"])
            #expect(try store.location(byExternalKey: "orca-tab:tab-1") == nil)
        }
    }

    @Test func nonOwningEventsAttachTheTabOnlyWhenNobodyOwnsIt() throws {
        try withReconciler { reconciler, store, clock in
            let id = try #require(try reconciler.apply(event: event(.sessionStart, "s1"), env: nil, now: clock.current)).ticketId
            #expect(try locationKeys(store, id) == ["claude:s1"])
            try reconciler.apply(event: event(.stop, "s1"), env: orca(), now: clock.current)  // 주인 없음 → 붙는다
            #expect(try locationKeys(store, id) == ["claude:s1", "orca-tab:tab-1"])
        }
    }

    @Test func aTicketCreatedByANonOwningEventTakesTheTab() throws {
        try withReconciler { reconciler, store, clock in
            let first = try #require(try reconciler.apply(event: event(.sessionStart, "s1"), env: orca(), now: clock.current)).ticketId
            let created = try #require(try reconciler.apply(event: event(.stop, "s2"), env: orca(), now: clock.current))
            #expect(created.created)
            #expect(try locationKeys(store, first) == ["claude:s1"])
            #expect(try locationKeys(store, created.ticketId) == ["claude:s2", "orca-tab:tab-1"])
        }
    }

    // MARK: 새 이벤트: StopFailure, PostToolUse

    @Test func stopFailureWaitsWithReasonError() throws {
        try withReconciler { reconciler, store, clock in
            let id = try #require(try reconciler.apply(event: event(.userPromptSubmit, prompt: "go"), env: nil, now: clock.current)).ticketId
            clock.advance(5)
            try reconciler.apply(event: event(.stopFailure), env: nil, now: clock.current)
            let ticket = try store.getTicket(id: id)
            #expect(ticket.status == .waiting && ticket.waitingReason == .error && ticket.lastActivityAt == clock.current)
            // 프롬프트를 다시 보내면 active로 돌아오고 이유는 지워진다.
            try reconciler.apply(event: event(.userPromptSubmit, prompt: "retry"), env: nil, now: clock.current)
            let retried = try store.getTicket(id: id)
            #expect(retried.status == .active && retried.waitingReason == nil)
        }
    }

    @Test func stopFailureCanCreateTheTicketToo() throws {
        try withReconciler { reconciler, store, clock in
            let outcome = try #require(try reconciler.apply(event: event(.stopFailure, "fresh"), env: nil, now: clock.current))
            let ticket = try store.getTicket(id: outcome.ticketId)
            #expect(outcome.created && ticket.status == .waiting && ticket.waitingReason == .error)
        }
    }

    @Test func postToolUseAfterAPermissionRequestResumesTheTicket() throws {
        try withReconciler { reconciler, store, clock in
            let id = try #require(try reconciler.apply(event: event(.permissionRequest), env: nil, now: clock.current)).ticketId
            #expect(try store.getTicket(id: id).waitingReason == .permission)
            clock.advance(10)
            try reconciler.apply(event: event(.postToolUse), env: nil, now: clock.current)
            let ticket = try store.getTicket(id: id)
            #expect(ticket.status == .active && ticket.waitingReason == nil && ticket.lastActivityAt == clock.current)
        }
    }

    @Test func postToolUseOtherwiseOnlyBumpsActivity() throws {
        try withReconciler { reconciler, store, clock in
            let id = try #require(try reconciler.apply(event: event(.sessionStart), env: nil, now: clock.current)).ticketId
            for (status, reason) in [(TicketStatus.active, WaitingReason?.none), (.waiting, .turnEnd), (.waiting, .error), (.waiting, .stale), (.blocked, nil), (.done, nil)] {
                try store.patchTicket(id: id, TicketPatch(status: status, waitingReason: .some(reason)))
                let before = try store.getTicket(id: id)
                clock.advance(60)
                try reconciler.apply(event: event(.postToolUse), env: nil, now: clock.current)
                let after = try store.getTicket(id: id)
                #expect(after.status == status && after.waitingReason == reason, "\(status) \(String(describing: reason))")
                #expect(after.lastActivityAt == clock.current && after.lastActivityAt > before.lastActivityAt)
            }
        }
    }

    @Test func postToolUseForAnUnknownSessionCreatesNothing() throws {
        try withReconciler { reconciler, store, clock in
            let outcome = try reconciler.apply(event: event(.postToolUse, "ghost"), env: orca(), now: clock.current)
            #expect(outcome == nil)
            #expect(try store.listTickets().isEmpty)
            #expect(try store.location(byExternalKey: "orca-tab:tab-1") == nil)
        }
    }

    // MARK: 입양 조건 (N15)

    @Test func onlyRecentPollerTicketsAreAdopted() throws {
        for (idle, adopted) in [(TimeInterval(9 * 60), true), (11 * 60, false)] {
            try withReconciler { reconciler, store, clock in
                let poller = try store.createTicket(title: "terminal", status: .inbox)
                try store.addLocation(
                    ticketId: poller.id, locator: .orcaTerminal(.init(terminalHandle: "term_1", tabId: "tab-1")),
                    source: .orcaSync, externalKey: "orca-tab:tab-1")
                clock.advance(idle)
                let outcome = try #require(try reconciler.apply(
                    event: event(.sessionStart, "th", agent: .codex), env: orca(), now: clock.current))
                #expect((outcome.ticketId == poller.id) == adopted, "idle \(idle)")
                #expect(outcome.created != adopted)
            }
        }
    }

    @Test func aTabTicketNotCreatedByThePollerIsNeverAdopted() throws {
        try withReconciler { reconciler, store, clock in
            let manual = try store.createTicket(title: "mine", status: .inbox)
            try store.addLocation(
                ticketId: manual.id, locator: .orcaTerminal(.init(terminalHandle: "term_1", tabId: "tab-1")),
                source: .manual, externalKey: "orca-tab:tab-1")
            let outcome = try #require(try reconciler.apply(event: event(.sessionStart), env: orca(), now: clock.current))
            #expect(outcome.created && outcome.ticketId != manual.id)
            #expect(try locationKeys(store, manual.id).isEmpty)  // 새 세션이 탭을 가져갔다
        }
    }

    // MARK: 빈 티켓 정리

    /// 폴러가 만든 탭 티켓을 새 세션이 입양하지 못하는 상황(오래 방치)에서 시작 상태를 만든다: 탭 위치만 있는 inbox 티켓.
    private func stalePollerTicket(_ store: Store, _ clock: TestClock, edit: (Store, Ticket) throws -> Void = { _, _ in }) throws -> Ticket {
        let poller = try store.createTicket(title: "terminal", status: .inbox)
        try store.addLocation(
            ticketId: poller.id, locator: .orcaTerminal(.init(terminalHandle: "term_1", tabId: "tab-1")),
            source: .orcaSync, externalKey: "orca-tab:tab-1")
        try edit(store, poller)
        clock.advance(Reconciler.adoptWindow + 60)
        return poller
    }

    @Test func aTicketLeftWithoutLocationsAndUntouchedIsDeletedWhenTheTabMovesAway() throws {
        try withReconciler { reconciler, store, clock in
            let poller = try stalePollerTicket(store, clock)
            let outcome = try #require(try reconciler.apply(event: event(.sessionStart), env: orca(), now: clock.current))
            #expect(outcome.created && outcome.ticketId != poller.id)
            #expect(throws: StoreError.self) { try store.getTicket(id: poller.id) }
            #expect(try store.listTickets().map(\.id) == [outcome.ticketId])
            #expect(try locationKeys(store, outcome.ticketId) == ["claude:s1", "orca-tab:tab-1"])
        }
    }

    @Test func aTicketTheUserTouchedSurvivesLosingItsLastLocation() throws {
        let edits: [(String, (Store, Ticket) throws -> Void)] = [
            ("pinned title", { store, t in try store.patchTicket(id: t.id, TicketPatch(title: "mine", pinnedTitle: true)) }),
            ("next action", { store, t in try store.patchTicket(id: t.id, TicketPatch(nextAction: .some("call back"))) }),
            ("note", { store, t in try store.patchTicket(id: t.id, TicketPatch(note: .some("context"))) }),
            ("priority", { store, t in try store.patchTicket(id: t.id, TicketPatch(priority: .some(1))) }),
        ]
        for (name, edit) in edits {
            try withReconciler { reconciler, store, clock in
                let poller = try stalePollerTicket(store, clock, edit: edit)
                try reconciler.apply(event: event(.sessionStart), env: orca(), now: clock.current)
                #expect(try store.getTicket(id: poller.id).id == poller.id, "\(name)")
                #expect(try locationKeys(store, poller.id).isEmpty, "\(name)")
            }
        }
    }

    @Test(arguments: [TicketStatus.waiting, .active, .blocked, .done])
    func aTicketWhoseStatusTheUserChangedSurvivesLosingItsLastLocation(status: TicketStatus) throws {
        try withReconciler { reconciler, store, clock in
            let poller = try stalePollerTicket(store, clock) { store, t in
                try store.patchTicket(id: t.id, TicketPatch(status: status))
            }
            let outcome = try #require(try reconciler.apply(event: event(.sessionStart), env: orca(), now: clock.current))
            #expect(outcome.ticketId != poller.id)
            #expect(try store.getTicket(id: poller.id).status == status, "\(status)")
            #expect(try locationKeys(store, poller.id).isEmpty)
        }
    }

    @Test func aTicketThatStillHasALocationIsNotDeleted() throws {
        try withReconciler { reconciler, store, clock in
            let first = try #require(try reconciler.apply(event: event(.sessionStart, "s1"), env: orca(), now: clock.current)).ticketId
            let second = try #require(try reconciler.apply(event: event(.sessionStart, "s2"), env: orca(), now: clock.current)).ticketId
            #expect(first != second)
            #expect(try locationKeys(store, first) == ["claude:s1"])  // 세션 위치가 남아 있어서 유지된다
            #expect(try store.listTickets().count == 2)
        }
    }

    @Test func adoptionMovesNoTabSoNothingIsDeleted() throws {
        try withReconciler { reconciler, store, clock in
            let poller = try store.createTicket(title: "terminal", status: .inbox)
            try store.addLocation(
                ticketId: poller.id, locator: .orcaTerminal(.init(terminalHandle: "term_1", tabId: "tab-1")),
                source: .orcaSync, externalKey: "orca-tab:tab-1")
            let outcome = try #require(try reconciler.apply(event: event(.sessionStart), env: orca(), now: clock.current))
            #expect(outcome.ticketId == poller.id)
            #expect(try store.listTickets().map(\.id) == [poller.id])
        }
    }

    @Test func storeDeleteTicketCascadesLocationsAndReportsWhetherItDeleted() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "x")
            try store.addLocation(ticketId: ticket.id, locator: .url(.init(url: "https://example.com")), source: .manual, externalKey: "k")
            #expect(try store.deleteTicket(id: ticket.id))
            #expect(try store.location(byExternalKey: "k") == nil)
            #expect(try store.deleteTicket(id: ticket.id) == false)
        }
    }

    // MARK: 중첩/헤드리스 세션 (S6)

    @Test func headlessClaudeSessionsAreIgnoredButInteractiveOnesAreNot() throws {
        let start = Data(#"{"hook_event_name":"SessionStart","session_id":"h1","cwd":"/Users/me/Work/app"}"#.utf8)
        let orcaEnv = ["ORCA_TAB_ID": "tab-1", "ORCA_TERMINAL_HANDLE": "term_1"]
        for (entrypoint, ignored) in [("sdk-cli", true), ("sdk-ts", true), ("cli", false), ("", false), (nil, false)] as [(String?, Bool)] {
            try withStore { store, clock, _ in
                var environment = orcaEnv
                if let entrypoint { environment["CLAUDE_CODE_ENTRYPOINT"] = entrypoint }
                let outcome = try Ingest.handle(
                    agent: "claude", input: start, environment: environment,
                    store: store, projectResolver: StubProjects(root: nil), now: clock.current)
                #expect((outcome == nil) == ignored, "\(String(describing: entrypoint))")
                let noTickets = try store.listTickets().isEmpty
                let noTab = try store.location(byExternalKey: "orca-tab:tab-1") == nil
                #expect(noTickets == ignored && noTab == ignored)
            }
        }
    }

    @Test func theEntrypointFilterIsClaudeOnly() throws {
        #expect(!Ingest.isNestedSession(agent: "codex", environment: ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli"]))
        #expect(Ingest.isNestedSession(agent: "claude", environment: ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli"]))
        #expect(!Ingest.isNestedSession(agent: "claude", environment: [:]))
        try withStore { store, clock, _ in
            let start = Data(#"{"hook_event_name":"SessionStart","session_id":"c1"}"#.utf8)
            let outcome = try Ingest.handle(
                agent: "codex", input: start, environment: ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli"],
                store: store, projectResolver: StubProjects(root: nil), now: clock.current)
            #expect(outcome?.created == true)
        }
    }

    @Test func codexNeverReportsStopFailure() throws {
        #expect(try AgentEvent.parse(agent: .codex, json: Data(#"{"hook_event_name":"StopFailure","session_id":"x"}"#.utf8)) == nil)
        #expect(try AgentEvent.parse(agent: .claude, json: Data(#"{"hook_event_name":"StopFailure","session_id":"x"}"#.utf8))?.kind == .stopFailure)
        #expect(try AgentEvent.parse(agent: .codex, json: Data(#"{"hook_event_name":"PostToolUse","session_id":"x"}"#.utf8))?.kind == .postToolUse)
    }

    // MARK: cwd / project

    @Test func missingCwdOnALaterEventKeepsTheKnownOne() throws {
        try withReconciler { reconciler, store, clock in
            try reconciler.apply(event: event(.sessionStart), env: nil, now: clock.current)
            try reconciler.apply(event: event(.stop, cwd: nil), env: nil, now: clock.current)
            #expect(try store.location(byExternalKey: "claude:s1")?.locator == .claudeCode(.init(sessionId: "s1", cwd: cwd)))
            try reconciler.apply(event: event(.stop, cwd: "/moved"), env: nil, now: clock.current)
            #expect(try store.location(byExternalKey: "claude:s1")?.locator == .claudeCode(.init(sessionId: "s1", cwd: "/moved")))
        }
    }

    @Test func projectPrefersWorktreePathThenGitRootThenCwd() throws {
        try withReconciler(root: "/Users/me/Work/mono") { reconciler, store, clock in
            let viaWorktree = try #require(try reconciler.apply(event: event(.sessionStart, "a"), env: orca(), now: clock.current)).ticketId
            #expect(try store.getTicket(id: viaWorktree).project == "app-wt")
            let viaGit = try #require(try reconciler.apply(event: event(.sessionStart, "b", cwd: "/Users/me/Work/mono/pkg/x"), env: nil, now: clock.current)).ticketId
            #expect(try store.getTicket(id: viaGit).project == "mono")
        }
        try withReconciler(root: nil) { reconciler, store, clock in
            let viaCwd = try #require(try reconciler.apply(event: event(.sessionStart, "c", cwd: "/tmp/scratch/"), env: nil, now: clock.current)).ticketId
            #expect(try store.getTicket(id: viaCwd).project == "scratch")
            // 워크트리 ID가 `::` 없이 UUID뿐이면 쓸 수 없으니 cwd로 넘어간다.
            let uuidOnly = try #require(try reconciler.apply(
                event: event(.sessionStart, "d"), env: orca(worktree: "5a8bd383-218e-43b3-bbae-132e65805ae5"), now: clock.current)).ticketId
            #expect(try store.getTicket(id: uuidOnly).project == "app")
        }
    }

    @Test func existingProjectIsNeverOverwrittenAndMissingOneIsFilled() throws {
        try withReconciler { reconciler, store, clock in
            let id = try #require(try reconciler.apply(event: event(.sessionStart), env: nil, now: clock.current)).ticketId
            #expect(try store.getTicket(id: id).project == "app")
            try store.patchTicket(id: id, TicketPatch(project: .some("mine")))
            try reconciler.apply(event: event(.stop), env: orca(), now: clock.current)
            #expect(try store.getTicket(id: id).project == "mine")

            try store.patchTicket(id: id, TicketPatch(project: .some(nil)))
            try reconciler.apply(event: event(.stop), env: nil, now: clock.current)
            #expect(try store.getTicket(id: id).project == "app")
        }
    }

    @Test func fileSystemProjectResolverWalksUpToTheGitEntry() throws {
        let root = NSTemporaryDirectory() + "jtm-git-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let deep = root + "/repo/a/b"
        try FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/repo/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/wt/sub", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root + "/wt/.git", contents: Data("gitdir: elsewhere".utf8))

        let resolver = FileSystemProjectResolver()
        #expect(resolver.gitTopLevel(containing: deep) == root + "/repo")
        #expect(resolver.gitTopLevel(containing: root + "/wt/sub") == root + "/wt")  // 워크트리는 .git이 파일이다
        #expect(resolver.gitTopLevel(containing: "relative/path") == nil)
    }
}

@Suite struct EventParsingTests {
    private func parse(_ agent: String, _ json: String, cwd: String? = nil) throws -> AgentEvent? {
        try Ingest.parse(agent: agent, input: Data(json.utf8), defaultCwd: cwd)
    }

    @Test func mapsHookEventNamesAndFields() throws {
        let e = try #require(try parse("claude", #"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/w","prompt":"hi"}"#))
        #expect(e == AgentEvent(agent: .claude, kind: .userPromptSubmit, sessionId: "s", cwd: "/w", prompt: "hi"))
    }

    @Test func unknownAndUnhandledEventsAreIgnoredSilently() throws {
        #expect(try parse("claude", #"{"hook_event_name":"Notification","session_id":"s"}"#) == nil)
        #expect(try parse("claude", #"{"hook_event_name":"PreToolUse","session_id":"s"}"#) == nil)
        #expect(try parse("claude", #"{"session_id":"s"}"#) == nil)
        #expect(try parse("codex", #"{"hook_event_name":"SessionEnd","session_id":"s"}"#) == nil)
    }

    @Test func fallsBackToTheProvidedCwd() throws {
        let e = try #require(try parse("codex", #"{"hook_event_name":"Stop","session_id":"s"}"#, cwd: "/here"))
        #expect(e.cwd == "/here")
    }

    @Test func rejectsBadInput() {
        #expect(throws: IngestError.self) { try parse("claude", "") }
        #expect(throws: IngestError.self) { try parse("claude", "not json") }
        #expect(throws: IngestError.self) { try parse("claude", "[1]") }
        #expect(throws: IngestError.self) { try parse("claude", #"{"hook_event_name":"Stop"}"#) }
        #expect(throws: IngestError.self) { try parse("gemini", #"{"hook_event_name":"Stop","session_id":"s"}"#) }
        #expect(throws: IngestError.self) {
            try Ingest.parse(agent: "claude", input: Data(repeating: 0x20, count: Ingest.inputLimit + 1))
        }
    }

    @Test func orcaEnvIgnoresEmptyValuesAndAbsence() {
        #expect(OrcaEnv(environment: ["PATH": "/bin"]) == nil)
        #expect(OrcaEnv(environment: ["ORCA_TAB_ID": ""]) == nil)
        #expect(OrcaEnv(environment: ["ORCA_TERMINAL_HANDLE": "term_1", "ORCA_TAB_ID": "t"])
                == OrcaEnv(terminalHandle: "term_1", tabId: "t", worktreeId: nil))
    }
}

@Suite struct SamplesReplayTests {
    /// 실측 샘플(+가짜 세션 하나)을 Ingest에 흘려 넣는다.
    @Test func replayingTheRealSamplesYieldsThreeTicketsWithTheExpectedShape() throws {
        let real = try loadHookSamples()
        #expect(real.count == 15 && real.allSatisfy(\.isAgent))
        let transcripts = NSTemporaryDirectory() + "jtm-samples-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: transcripts) }
        let samples = try materializeTranscripts(real, in: transcripts) + (try syntheticSamples())
        try withStore { store, clock, _ in
            for sample in samples {
                clock.advance(1)
                try Ingest.handle(
                    agent: sample.agent, input: sample.payload, environment: sample.env,
                    store: store, projectResolver: StubProjects(root: nil), now: clock.current)
            }
            let tickets = try store.listTickets(statuses: nil).sorted { $0.id < $1.id }
            #expect(tickets.count == 3)
            func keys(_ ticket: Ticket) throws -> [String] { try locationKeys(store, ticket.id) }

            // 1) Claude 첫 세션: 같은 탭에 Codex가 새로 떠서 탭 위치를 넘겼다. SessionEnd가 기록되고 자동 완료됐다.
            let claudeOld = tickets[0]
            #expect(try keys(claudeOld) == ["claude:891dc7a6-454b-44f5-8ad2-5998d41d8aa5"])
            #expect(claudeOld.title == "synthetic prompt one for the claude session")
            // 유지가 아니라서 SessionEnd로 자동 완료됐다(대기 이유는 지워진다).
            #expect(claudeOld.status == .done && claudeOld.waitingReason == nil && claudeOld.endedAt != nil)
            #expect(claudeOld.project == "sample-project")

            // 2) Codex 세션: 같은 탭의 최신 세션.
            let codex = tickets[1]
            #expect(try keys(codex) == ["codex:c4b7a3bd-0820-4189-86cb-2932b676123a", "orca-tab:c7b15c94-1a9e-4012-b930-e17735ac8136"])
            #expect(codex.title == "synthetic codex prompt one")
            #expect(codex.status == .waiting && codex.waitingReason == .permission && codex.endedAt == nil)
            let thread = try #require(try store.location(byExternalKey: "codex:c4b7a3bd-0820-4189-86cb-2932b676123a"))
            #expect(thread.locator == .codexThread(.init(
                threadId: "c4b7a3bd-0820-4189-86cb-2932b676123a", cwd: "/Users/me/Work/sample-project")))

            // 3) 가짜 세션: SessionStart 없이 Stop으로 시작(→ 자리표시자), 이어진 프롬프트가 제목이 된다.
            let synthetic = tickets[2]
            #expect(try keys(synthetic) == ["claude:synthetic-session-0001", "orca-tab:synthetic-tab-0001"])
            #expect(synthetic.title == "synthetic prompt" && synthetic.project == "synthetic-project")
            #expect(synthetic.status == .waiting && synthetic.waitingReason == .turnEnd)
        }
    }

    @Test func notificationSamplesAreIgnored() throws {
        try withStore { store, clock, _ in
            let notifications = try (loadHookSamples() + syntheticSamples()).filter { $0.event == "Notification" }
            #expect(!notifications.isEmpty)
            for sample in notifications {
                let outcome = try Ingest.handle(
                    agent: sample.agent, input: sample.payload, environment: sample.env,
                    store: store, projectResolver: StubProjects(root: nil), now: clock.current)
                #expect(outcome == nil)
            }
            #expect(try store.listTickets().isEmpty)
        }
    }
}
