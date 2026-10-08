import Foundation
import SQLite3
import Testing
@testable import WWICore

// 오케스트레이션 워커 세션은 티켓으로 수집하지 않는다(docs/01-product/auto-capture.md).

private struct NoProject: ProjectResolver {
    func gitTopLevel(containing cwd: String) -> String? { nil }
}

private let cwd = "/Users/me/Work/app"

private func env(tab: String = "tab-1", handle: String = "term_1") -> OrcaEnv {
    OrcaEnv(terminalHandle: handle, tabId: tab, worktreeId: "wt-uuid::/Users/me/Work/app-wt")
}

private func event(
    _ kind: AgentEventKind, _ session: String = "s1", agent: AgentType = .claude, prompt: String? = nil
) -> AgentEvent {
    AgentEvent(agent: agent, kind: kind, sessionId: session, cwd: cwd, prompt: prompt)
}

private func withReconciler(_ body: (Reconciler, Store, TestClock) throws -> Void) throws {
    try withStore { store, clock, _ in
        try body(Reconciler(store: store, projectResolver: NoProject()), store, clock)
    }
}

@Suite struct WorkerIgnoreTests {
    // MARK: 프롬프트 표지

    @Test(arguments: [(AgentType.claude, WorkerFixtures.claudePrompt), (.codex, WorkerFixtures.codexPrompt)])
    func aWorkerPromptRemovesTheTicketAndLaterEventsAreIgnored(agent: AgentType, prompt: String) throws {
        try withReconciler { reconciler, store, clock in
            let key = "\(agent.rawValue):s1"
            // SessionStart는 프롬프트보다 먼저 와서 잠깐 티켓이 생긴다.
            let started = try reconciler.apply(event: event(.sessionStart, agent: agent), env: env(), now: clock.current)
            #expect(started?.created == true)
            #expect(try store.listTickets().count == 1)

            let outcome = try reconciler.apply(event: event(.userPromptSubmit, agent: agent, prompt: prompt), env: env(), now: clock.current)
            #expect(outcome == nil)
            #expect(try store.listTickets(statuses: nil).isEmpty)
            #expect(try store.location(byExternalKey: key) == nil && store.location(byExternalKey: "orca-tab:tab-1") == nil)
            #expect(try store.ignoredSessions().map(\.externalKey) == [key])
            #expect(try store.ignoredSessions().first?.reason == OrcaWorker.promptReason)

            // 이후 이벤트는 티켓을 되살리지 않는다.
            for kind in [AgentEventKind.stop, .permissionRequest, .postToolUse, .userPromptSubmit, .sessionStart, .sessionEnd] {
                let result = try reconciler.apply(event: event(kind, agent: agent, prompt: "hello"), env: env(), now: clock.current)
                #expect(result == nil, "\(kind)")
            }
            #expect(try store.listTickets().isEmpty)
        }
    }

    @Test func aWorkerPromptWithoutAnEarlierSessionStartCreatesNothing() throws {
        try withReconciler { reconciler, store, clock in
            let outcome = try reconciler.apply(
                event: event(.userPromptSubmit, prompt: WorkerFixtures.claudePrompt), env: env(), now: clock.current)
            #expect(outcome == nil)
            #expect(try store.listTickets().isEmpty && store.location(byExternalKey: "orca-tab:tab-1") == nil)
            #expect(try store.ignoredSessions().map(\.externalKey) == ["claude:s1"])
        }
    }

    @Test func aWorkerPromptAlsoRecordsTheTerminalHandleSoThePollerDoesNotRecreateTheTab() throws {
        try withReconciler { reconciler, store, clock in
            try reconciler.apply(event: event(.userPromptSubmit, agent: .codex, prompt: WorkerFixtures.codexPrompt), env: env(handle: "term_w"), now: clock.current)
            #expect(try store.isOrcaWorkerHandle("term_w"))
        }
    }

    @Test func aUserPromptThatMerelyMentionsOrcaIsNotIgnored() throws {
        try withReconciler { reconciler, store, clock in
            let prompts = [
                "Why does the Orca worker list show a dispatched worker twice?",
                "You are working inside Orca, a multi-agent IDE. Explain what that means.",  // 표지 하나만
                "Please carry out this task from my Orca coordinator: rename the variable",  // 감싸는 말만
                "dispatched worker",
            ]
            for (index, prompt) in prompts.enumerated() {
                let session = "s\(index)"
                let outcome = try reconciler.apply(
                    event: event(.userPromptSubmit, session, prompt: prompt), env: nil, now: clock.current)
                #expect(outcome?.created == true, "\(prompt)")
            }
            #expect(try store.listTickets().count == prompts.count)
            #expect(try store.ignoredSessions().isEmpty)
        }
    }

    @Test func markersBeyondTheFirstTwoThousandCharactersDoNotCount() throws {
        try withReconciler { reconciler, store, clock in
            let filler = String(repeating: "x", count: OrcaWorker.promptScanLimit)
            let outcome = try reconciler.apply(
                event: event(.userPromptSubmit, prompt: filler + WorkerFixtures.preamble), env: nil, now: clock.current)
            #expect(outcome?.created == true && store.ignoredSessionsIsEmpty)
        }
    }

    @Test func aWorkerPromptOnlyCountsOnUserPromptSubmit() throws {
        // 프롬프트가 없는 이벤트(Stop 등)는 표지를 볼 수 없다. 이벤트 종류가 다르면 prompt 필드가 있어도 무시한다.
        try withReconciler { reconciler, store, clock in
            let outcome = try reconciler.apply(
                event: event(.stop, prompt: WorkerFixtures.claudePrompt), env: nil, now: clock.current)
            #expect(outcome?.created == true && store.ignoredSessionsIsEmpty)
        }
    }

    // MARK: 워커 handle

    @Test func aWorkerTerminalHandleIgnoresEverythingFromTheFirstEventOn() throws {
        try withReconciler { reconciler, store, clock in
            try store.upsertOrcaWorkerHandle("term_w", runId: "run_1")
            for kind in [AgentEventKind.sessionStart, .userPromptSubmit, .stop, .permissionRequest] {
                let outcome = try reconciler.apply(
                    event: event(kind, prompt: "ordinary prompt"), env: env(tab: "tab-w", handle: "term_w"), now: clock.current)
                #expect(outcome == nil, "\(kind)")
            }
            #expect(try store.listTickets().isEmpty && store.location(byExternalKey: "orca-tab:tab-w") == nil)
            let ignored = try store.ignoredSessions()
            #expect(ignored.map(\.externalKey) == ["claude:s1"] && ignored[0].reason == OrcaWorker.handleReason)
        }
    }

    @Test func aWorkerHandleNeverTakesTheTabFromAnotherTicket() throws {
        try withReconciler { reconciler, store, clock in
            let mine = try #require(try reconciler.apply(event: event(.sessionStart, "user"), env: env(tab: "tab-1", handle: "term_1"), now: clock.current))
            try store.upsertOrcaWorkerHandle("term_1", runId: nil)
            _ = try reconciler.apply(event: event(.userPromptSubmit, "worker", prompt: "hi"), env: env(tab: "tab-1", handle: "term_1"), now: clock.current)
            #expect(try store.location(byExternalKey: "orca-tab:tab-1")?.ticketId == mine.ticketId)
            #expect(try store.listTickets().count == 1)
        }
    }

    @Test func aTerminalThatIsNotAWorkerIsNotAffectedByTheWorkerSet() throws {
        try withReconciler { reconciler, store, clock in
            try store.upsertOrcaWorkerHandle("term_w", runId: "run_1")
            let outcome = try reconciler.apply(event: event(.sessionStart), env: env(handle: "term_other"), now: clock.current)
            #expect(outcome?.created == true && store.ignoredSessionsIsEmpty)
        }
    }

    // MARK: 손댄 티켓은 지키고, 지울 때도 다른 세션은 지키지 않는다

    @Test(arguments: [
        TicketPatch(title: "Mine", pinnedTitle: true),
        TicketPatch(nextAction: .some("call back")),
        TicketPatch(note: .some("keep")),
        TicketPatch(priority: .some(1)),
        TicketPatch(status: .blocked),
        TicketPatch(status: .done),
    ])
    func aTouchedTicketSurvivesButTheSessionIsStillIgnored(patch: TicketPatch) throws {
        try withReconciler { reconciler, store, clock in
            let started = try #require(try reconciler.apply(event: event(.sessionStart), env: env(), now: clock.current))
            try store.patchTicket(id: started.ticketId, patch)
            let before = try store.getTicket(id: started.ticketId)
            let outcome = try reconciler.apply(
                event: event(.userPromptSubmit, prompt: WorkerFixtures.claudePrompt), env: env(), now: clock.current)
            #expect(outcome == nil)
            #expect(try store.getTicket(id: started.ticketId) == before)
            #expect(try store.ignoredSessions().map(\.externalKey) == ["claude:s1"])
            // 이후 이벤트는 티켓을 바꾸지 않는다.
            _ = try reconciler.apply(event: event(.stop), env: env(), now: clock.current)
            #expect(try store.getTicket(id: started.ticketId) == before)
        }
    }

    @Test func aTicketWithAnotherSessionLocationIsKept() throws {
        try withReconciler { reconciler, store, clock in
            let started = try #require(try reconciler.apply(event: event(.sessionStart), env: env(), now: clock.current))
            try store.addLocation(
                ticketId: started.ticketId, locator: .codexThread(.init(threadId: "other")), source: .hook, externalKey: "codex:other")
            _ = try reconciler.apply(event: event(.userPromptSubmit, prompt: WorkerFixtures.claudePrompt), env: env(), now: clock.current)
            #expect(try store.listTickets().count == 1)
            #expect(try store.ignoredSessions().map(\.externalKey) == ["claude:s1"])
        }
    }

    @Test func aPollerTicketAdoptedByTheWorkerSessionIsRemovedToo() throws {
        try withReconciler { reconciler, store, clock in
            // 폴러가 먼저 탭 티켓을 만들었고 워커 세션이 입양한 경우.
            let poller = try store.createTicket(NewTicket(title: "t", status: .inbox))
            try store.addLocation(
                ticketId: poller.id, locator: .orcaTerminal(.init(terminalHandle: "term_1", tabId: "tab-1")),
                source: .orcaSync, externalKey: "orca-tab:tab-1")
            _ = try reconciler.apply(event: event(.sessionStart), env: env(), now: clock.current)
            #expect(try store.locations(ticketId: poller.id).contains { $0.externalKey == "claude:s1" })
            _ = try reconciler.apply(event: event(.userPromptSubmit, prompt: WorkerFixtures.claudePrompt), env: env(), now: clock.current)
            #expect(try store.listTickets().isEmpty)
        }
    }

    // MARK: 저장소

    @Test func theIgnoreListAndWorkerHandlesRoundTrip() throws {
        try withStore { store, clock, path in
            #expect(try !store.isSessionIgnored("claude:x"))
            try store.ignoreSession("claude:x", reason: "first")
            clock.advance(60)
            try store.ignoreSession("claude:x", reason: "second")  // 처음 기록을 유지한다
            #expect(try store.isSessionIgnored("claude:x") && !store.isSessionIgnored("codex:x"))
            #expect(try store.ignoredSessions().map(\.reason) == ["first"])
            #expect(throws: StoreError.self) { try store.ignoreSession("", reason: "r") }

            try store.upsertOrcaWorkerHandle("term_a", runId: "run_1")
            try store.upsertOrcaWorkerHandle("term_a", runId: nil)  // run_id를 지우지 않는다
            try store.upsertOrcaWorkerHandle("term_b", runId: nil)
            #expect(try store.orcaWorkerHandles() == ["term_a", "term_b"])
            #expect(try store.isOrcaWorkerHandle("term_a") && !store.isOrcaWorkerHandle("term_c"))
            #expect(rawSQL(path, "SELECT run_id FROM orca_worker_handles WHERE handle = 'term_a'") { String(cString: sqlite3_column_text($0, 0)) } == "run_1")

            #expect(try store.meta("k") == nil)
            try store.setMeta("k", "1")
            try store.setMeta("k", "2")
            #expect(try store.meta("k") == "2")
        }
    }
}

private extension Store {
    var ignoredSessionsIsEmpty: Bool { ((try? ignoredSessions()) ?? [(" ", nil)]).isEmpty }
}
