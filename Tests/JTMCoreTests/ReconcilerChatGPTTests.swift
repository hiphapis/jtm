import Foundation
import Testing
@testable import JTMCore

// Codex의 "참조한 ChatGPT 대화" 첫 프롬프트가 티켓 제목, chatgpt_chat 위치, 프로젝트에 반영되는 규칙.

private struct NoRepo: ProjectResolver {
    func gitTopLevel(containing cwd: String) -> String? { nil }
}

private func prompt(_ text: String, session: String = "th-1", cwd: String? = ChatGPTFixtures.projectCwd) -> AgentEvent {
    AgentEvent(agent: .codex, kind: .userPromptSubmit, sessionId: session, cwd: cwd, prompt: text)
}

private func withReconciler(_ body: (Reconciler, Store, TestClock) throws -> Void) throws {
    try withStore { store, clock, _ in
        try body(Reconciler(store: store, projectResolver: NoRepo()), store, clock)
    }
}

private let orcaEnv = OrcaEnv(terminalHandle: "term_1", tabId: "tab-1", worktreeId: "wt-uuid::/Users/me/.codex/.chatgpt-projects/x")

@Suite struct ReconcilerChatGPTTests {
    @Test func headerWithRequestTitlesTheTicketAttachesTheChatAndSetsTheProject() throws {
        try withReconciler { reconciler, store, clock in
            let outcome = try #require(try reconciler.apply(event: prompt(ChatGPTFixtures.withRequest()), env: orcaEnv, now: clock.current))
            let ticket = try store.getTicket(id: outcome.ticketId)
            #expect(ticket.title == "Write the release notes for version two")
            #expect(ticket.project == "ChatGPT")
            let chat = try #require(try store.location(byExternalKey: "chatgpt:\(ChatGPTFixtures.conversationId)"))
            #expect(chat.ticketId == ticket.id && chat.source == .hook)
            #expect(chat.locator == .chatgptChat(.init(
                chatId: ChatGPTFixtures.conversationId, url: "https://chatgpt.com/c/\(ChatGPTFixtures.conversationId)")))
            let locations = try store.locations(ticketId: ticket.id)
            #expect(locations.compactMap(\.externalKey).sorted() == ["chatgpt:\(ChatGPTFixtures.conversationId)", "codex:th-1", "orca-tab:tab-1"])
        }
    }

    @Test func headerWithoutRequestUsesTheReferencedConversationTitle() throws {
        try withReconciler { reconciler, store, clock in
            let outcome = try #require(try reconciler.apply(event: prompt(ChatGPTFixtures.withoutRequest()), env: nil, now: clock.current))
            #expect(try store.getTicket(id: outcome.ticketId).title == ChatGPTFixtures.referencedTitle)
            #expect(try store.location(byExternalKey: "chatgpt:\(ChatGPTFixtures.conversationId)")?.ticketId == outcome.ticketId)
        }
    }

    @Test func headerWithNeitherRequestNorTitleLeavesThePlaceholderTitle() throws {
        try withReconciler { reconciler, store, clock in
            let outcome = try #require(try reconciler.apply(
                event: prompt(ChatGPTFixtures.withoutRequest(title: nil)), env: nil, now: clock.current))
            #expect(try store.getTicket(id: outcome.ticketId).title == "codex session")
        }
    }

    @Test func aTitleSetByAnEarlierPromptIsNotReplacedByAHeaderWithoutAnyText() throws {
        try withReconciler { reconciler, store, clock in
            let first = try #require(try reconciler.apply(event: prompt("Fix the flaky test"), env: nil, now: clock.current))
            try reconciler.apply(event: prompt(ChatGPTFixtures.withoutRequest(title: nil)), env: nil, now: clock.current)
            #expect(try store.getTicket(id: first.ticketId).title == "Fix the flaky test")
        }
    }

    @Test func malformedJSONKeepsTheRequestTitleButAttachesNoChat() throws {
        try withReconciler { reconciler, store, clock in
            let outcome = try #require(try reconciler.apply(event: prompt(ChatGPTFixtures.malformedJSON), env: nil, now: clock.current))
            #expect(try store.getTicket(id: outcome.ticketId).title == "Summarize the open questions")
            #expect(try store.locations(ticketId: outcome.ticketId).allSatisfy { $0.kind != .chatgptChat })
        }
    }

    @Test func aNormalPromptIsUnaffected() throws {
        try withReconciler { reconciler, store, clock in
            let outcome = try #require(try reconciler.apply(
                event: prompt("Fix the flaky test", cwd: "/Users/me/Work/app"), env: nil, now: clock.current))
            let ticket = try store.getTicket(id: outcome.ticketId)
            #expect(ticket.title == "Fix the flaky test" && ticket.project == "app")
            #expect(try store.locations(ticketId: ticket.id).map(\.kind) == [.codexThread])
        }
    }

    @Test func repeatingTheSamePromptKeepsOneChatLocation() throws {
        try withReconciler { reconciler, store, clock in
            for _ in 0..<3 { try reconciler.apply(event: prompt(ChatGPTFixtures.withRequest()), env: nil, now: clock.current) }
            #expect(try store.listTickets().count == 1)
            #expect(try store.locations(externalKeyPrefix: "chatgpt:").count == 1)
        }
    }

    @Test func aChatAlreadyOnAnotherTicketIsNotStolen() throws {
        try withReconciler { reconciler, store, clock in
            let other = try store.createTicket(title: "Mine")
            let existing = try store.addLocation(
                ticketId: other.id,
                locator: .chatgptChat(.init(chatId: ChatGPTFixtures.conversationId, url: "https://chatgpt.com/c/\(ChatGPTFixtures.conversationId)")),
                source: .manual, externalKey: "chatgpt:\(ChatGPTFixtures.conversationId)")
            let outcome = try #require(try reconciler.apply(event: prompt(ChatGPTFixtures.withRequest()), env: nil, now: clock.current))
            #expect(outcome.ticketId != other.id)
            #expect(try store.location(byExternalKey: "chatgpt:\(ChatGPTFixtures.conversationId)") == existing)
            // 제목은 그대로 반영된다: 위치를 못 붙인 것과 무관하다.
            #expect(try store.getTicket(id: outcome.ticketId).title == "Write the release notes for version two")
        }
    }

    @Test func theChatIsNotTheDestinationEvenWhenItIsTheNewestLocation() throws {
        try withReconciler { reconciler, store, clock in
            let outcome = try #require(try reconciler.apply(event: prompt(ChatGPTFixtures.withRequest()), env: nil, now: clock.current))
            clock.advance(60)
            // 대화 위치만 나중에 다시 보인 경우(예: 사용자가 같은 대화를 다시 붙여 넣음).
            try store.upsertLocation(
                byExternalKey: "chatgpt:\(ChatGPTFixtures.conversationId)", ticketId: outcome.ticketId,
                locator: .chatgptChat(.init(chatId: ChatGPTFixtures.conversationId, url: "https://chatgpt.com/c/\(ChatGPTFixtures.conversationId)")),
                source: .hook)
            let locations = try store.locations(ticketId: outcome.ticketId)
            let chat = try #require(locations.first { $0.kind == .chatgptChat })
            let thread = try #require(locations.first { $0.kind == .codexThread })
            #expect(chat.lastSeenAt > thread.lastSeenAt)
            #expect(locations.primary?.kind == .codexThread)
            // Orca 탭이 붙으면 그쪽이 먼저다.
            try reconciler.apply(event: prompt("again"), env: orcaEnv, now: clock.current)
            #expect(try store.locations(ticketId: outcome.ticketId).primary?.kind == .orcaTerminal)
        }
    }

    @Test func chatGPTProjectFolderSetsTheProjectOnlyWhenItIsEmpty() throws {
        try withReconciler { reconciler, store, clock in
            // 이미 프로젝트가 있는 티켓(다른 cwd로 시작)은 덮어쓰지 않는다.
            let first = try #require(try reconciler.apply(
                event: AgentEvent(agent: .codex, kind: .sessionStart, sessionId: "th-2", cwd: "/Users/me/Work/app"),
                env: nil, now: clock.current))
            try reconciler.apply(event: prompt("hello", session: "th-2"), env: nil, now: clock.current)
            #expect(try store.getTicket(id: first.ticketId).project == "app")
            // 프로젝트가 비어 있던 티켓은 채운다.
            let blank = try store.createTicket(title: "x")
            try store.addLocation(ticketId: blank.id, locator: .codexThread(.init(threadId: "th-3")), source: .hook, externalKey: "codex:th-3")
            try reconciler.apply(event: prompt("hello", session: "th-3"), env: nil, now: clock.current)
            #expect(try store.getTicket(id: blank.id).project == "ChatGPT")
        }
    }

    @Test func projectPathDetectionNeedsAFolderUnderChatGPTProjects() {
        #expect(Reconciler.isChatGPTProjectPath(ChatGPTFixtures.projectCwd))
        #expect(Reconciler.isChatGPTProjectPath(ChatGPTFixtures.projectCwd + "/sub/dir"))
        #expect(!Reconciler.isChatGPTProjectPath("/Users/me/.codex/.chatgpt-projects"))
        #expect(!Reconciler.isChatGPTProjectPath("/Users/me/.codex/sessions/x"))
        #expect(!Reconciler.isChatGPTProjectPath("/Users/me/Work/.chatgpt-projects/x"))
        #expect(!Reconciler.isChatGPTProjectPath("/Users/me/.codex/.chatgpt-projects-old/x"))
    }
}

/// 실제 `jtm ingest codex` 프로세스: 머리말 프롬프트 한 건이 제목, 위치, 프로젝트로 나타난다.
@Suite struct IngestChatGPTHeaderCLITests {
    @Test func headerPromptThroughTheProcessGivesTitleChatLocationAndProject() throws {
        let directory = NSTemporaryDirectory() + "jtm-chatgpt-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let db = directory + "/jtm.sqlite"
        let payload: [String: Any] = [
            "hook_event_name": "UserPromptSubmit", "session_id": "th-9", "cwd": ChatGPTFixtures.projectCwd,
            "prompt": ChatGPTFixtures.withRequest(),
        ]
        let result = jtm(["ingest", "codex"], db: db, environment: ["JTM_LOG_PATH": directory + "/ingest.log"],
                         stdin: try JSONSerialization.data(withJSONObject: payload))
        #expect(result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty)
        let ticket = try #require(jtm(["ls", "--all", "--json"], db: db).array?.first)
        #expect(ticket["title"] as? String == "Write the release notes for version two")
        #expect(ticket["project"] as? String == "ChatGPT")
        let keys = (ticket["locations"] as? [[String: Any]] ?? []).compactMap { $0["externalKey"] as? String }.sorted()
        #expect(keys == ["chatgpt:\(ChatGPTFixtures.conversationId)", "codex:th-9"])
    }
}
