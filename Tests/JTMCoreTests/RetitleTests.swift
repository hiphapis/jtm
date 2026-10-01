import Foundation
import Testing
@testable import JTMCore

// `jtm retitle`: 머리말 제목 복구. Codex 세션 기록(rollout)은 가짜 값으로 임시 폴더에 만든다.

private let thread = "00000000-0000-4000-8000-0000000000a1"
private let headerTitle = "## Referenced ChatGPT conversation: The user referenced a pr"

private func jsonLine(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private func userMessage(_ text: String) -> String {
    jsonLine(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]])
}

/// 실측한 모양: 큰 session_meta, 합성 사용자 메시지(머리말 아님), 그다음 머리말 프롬프트.
private func rolloutLines(prompt: String?, bigMeta: Bool = false) -> [String] {
    var lines = [
        jsonLine(["type": "session_meta", "payload": ["id": thread, "cwd": ChatGPTFixtures.projectCwd, "base_instructions": bigMeta ? String(repeating: "x", count: 600_000) : "base"]]),
        jsonLine(["type": "event_msg", "payload": ["type": "task_started"]]),
        userMessage("Synthetic environment note without any header"),
    ]
    if let prompt { lines.append(userMessage(prompt)) }
    lines.append(jsonLine(["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "ok"]]]]))
    return lines
}

private func withCodexHome(_ files: [String: [String]], _ body: (String) throws -> Void) throws {
    let home = NSTemporaryDirectory() + "jtm-codex-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: home) }
    for (threadId, lines) in files {
        let directory = home + "/sessions/2026/09/30"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(toFile: directory + "/rollout-2026-09-30T15-10-37-\(threadId).jsonl", atomically: true, encoding: .utf8)
    }
    try body(home)
}

@discardableResult
private func headerTicket(
    _ store: Store, threadId: String = thread, title: String = headerTitle, project: String? = "g-p-00000000000040008000000000000001-example",
    pinned: Bool = false, cwd: String = ChatGPTFixtures.projectCwd
) throws -> Ticket {
    let ticket = try store.createTicket(NewTicket(title: title, status: .waiting, project: project, pinnedTitle: pinned))
    try store.addLocation(ticketId: ticket.id, locator: .codexThread(.init(threadId: threadId, cwd: cwd)), source: .hook, externalKey: "codex:\(threadId)")
    return ticket
}

@Suite struct RetitleTests {
    @Test func repairsTitleProjectAndChatLocationFromTheRolloutAndIsIdempotent() throws {
        try withCodexHome([thread: rolloutLines(prompt: ChatGPTFixtures.withRequest(), bigMeta: true)]) { home in
            try withStore { store, _, _ in
                let ticket = try headerTicket(store)
                let retitler = Retitler(store: store, codexHome: home)

                let dry = try retitler.retitle(dryRun: true)
                #expect(dry.updated.count == 1 && dry.unresolved.isEmpty)
                #expect(try store.getTicket(id: ticket.id).title == headerTitle)  // 드라이런은 아무것도 바꾸지 않는다
                #expect(try store.locations(externalKeyPrefix: "chatgpt:").isEmpty)

                let real = try retitler.retitle(dryRun: false)
                #expect(real == dry)
                let entry = try #require(real.updated.first)
                #expect(entry.id == ticket.id && entry.newTitle == "Write the release notes for version two")
                #expect(entry.newProject == "ChatGPT" && entry.attachedChat == ChatGPTFixtures.conversationId)
                let fixed = try store.getTicket(id: ticket.id)
                #expect(fixed.title == "Write the release notes for version two" && fixed.project == "ChatGPT" && !fixed.pinnedTitle)
                let chat = try #require(try store.location(byExternalKey: "chatgpt:\(ChatGPTFixtures.conversationId)"))
                #expect(chat.ticketId == ticket.id && chat.source == .hook)
                #expect(chat.locator == .chatgptChat(.init(chatId: ChatGPTFixtures.conversationId, url: "https://chatgpt.com/c/\(ChatGPTFixtures.conversationId)")))
                #expect(try store.locations(ticketId: ticket.id).primary?.kind == .codexThread)

                #expect(try retitler.retitle(dryRun: false) == RetitleReport())  // 멱등
            }
        }
    }

    @Test func aHeaderWithoutRequestUsesTheReferencedTitle() throws {
        try withCodexHome([thread: rolloutLines(prompt: ChatGPTFixtures.withoutRequest())]) { home in
            try withStore { store, _, _ in
                let ticket = try headerTicket(store)
                try Retitler(store: store, codexHome: home).retitle(dryRun: false)
                #expect(try store.getTicket(id: ticket.id).title == ChatGPTFixtures.referencedTitle)
            }
        }
    }

    @Test func eventMsgUserMessagesAreReadToo() throws {
        let lines = [jsonLine(["type": "event_msg", "payload": ["type": "user_message", "message": ChatGPTFixtures.withRequest(request: "From event")]])]
        try withCodexHome([thread: lines]) { home in
            try withStore { store, _, _ in
                let ticket = try headerTicket(store)
                try Retitler(store: store, codexHome: home).retitle(dryRun: false)
                #expect(try store.getTicket(id: ticket.id).title == "From event")
            }
        }
    }

    @Test func unresolvedTicketsAreReportedWithAReasonAndLeftAlone() throws {
        try withCodexHome([
            "00000000-0000-4000-8000-0000000000b1": rolloutLines(prompt: nil),
            "00000000-0000-4000-8000-0000000000b2": rolloutLines(prompt: ChatGPTFixtures.withoutRequest(title: nil)),
        ]) { home in
            try withStore { store, _, _ in
                let noThread = try store.createTicket(NewTicket(title: headerTitle))
                let noFile = try headerTicket(store, threadId: "00000000-0000-4000-8000-0000000000b0", project: "app")
                let noHeader = try headerTicket(store, threadId: "00000000-0000-4000-8000-0000000000b1", project: "app")
                let noText = try headerTicket(store, threadId: "00000000-0000-4000-8000-0000000000b2", project: "app")
                let report = try Retitler(store: store, codexHome: home).retitle(dryRun: false)
                let reasons = Dictionary(uniqueKeysWithValues: report.unresolved.map { ($0.id, $0.reason ?? "") })
                #expect(reasons == [
                    noThread.id: Retitler.unresolvedNoThread, noFile.id: Retitler.unresolvedNoRollout,
                    noHeader.id: Retitler.unresolvedNoHeader, noText.id: Retitler.unresolvedNoText,
                ])
                for ticket in [noThread, noFile, noHeader, noText] { #expect(try store.getTicket(id: ticket.id).title == headerTitle) }
                // 대화 ID는 있으니 위치는 붙는다(제목은 못 고쳐도).
                #expect(report.updated.map(\.id) == [noText.id] && report.updated.first?.attachedChat == ChatGPTFixtures.conversationId)
                // 못 고친 티켓은 다시 실행해도 계속 보고된다.
                #expect(try Retitler(store: store, codexHome: home).retitle(dryRun: true).unresolved.count == 4)
            }
        }
    }

    @Test func aPinnedTitleIsKeptButItsProjectIsStillFixed() throws {
        try withCodexHome([thread: rolloutLines(prompt: ChatGPTFixtures.withRequest())]) { home in
            try withStore { store, _, _ in
                let ticket = try headerTicket(store, title: "My own title", pinned: true)
                let pinnedRemnant = try headerTicket(store, threadId: "00000000-0000-4000-8000-0000000000b9", pinned: true)
                let report = try Retitler(store: store, codexHome: home).retitle(dryRun: false)
                #expect(report.updated.map(\.id) == [ticket.id, pinnedRemnant.id] && report.unresolved.isEmpty)
                #expect(try store.getTicket(id: ticket.id).title == "My own title" && store.getTicket(id: ticket.id).project == "ChatGPT")
                #expect(try store.getTicket(id: pinnedRemnant.id).title == headerTitle)
                #expect(try store.locations(externalKeyPrefix: "chatgpt:").isEmpty)
            }
        }
    }

    @Test func ordinaryTicketsAreNotTouched() throws {
        try withCodexHome([thread: rolloutLines(prompt: ChatGPTFixtures.withRequest())]) { home in
            try withStore { store, _, _ in
                let plain = try headerTicket(store, title: "Fix the flaky test", project: "app", cwd: "/Users/me/Work/app")
                let lookalike = try headerTicket(store, threadId: "00000000-0000-4000-8000-0000000000b8", title: "Fix it", project: "g-p-example", cwd: "/Users/me/Work/app")
                let manual = try store.createTicket(NewTicket(title: "Notes", project: "g-p-note"))
                let report = try Retitler(store: store, codexHome: home).retitle(dryRun: false)
                #expect(report == RetitleReport())
                #expect(try store.getTicket(id: plain.id).project == "app" && store.getTicket(id: lookalike.id).project == "g-p-example")
                #expect(try store.getTicket(id: manual.id).project == "g-p-note")
            }
        }
    }

    @Test func anEmptyProjectInAChatGPTFolderIsFilledAndAnotherProjectIsKept() throws {
        try withCodexHome([:]) { home in
            try withStore { store, _, _ in
                let blank = try headerTicket(store, title: "Fine title", project: nil)
                let other = try headerTicket(store, threadId: "00000000-0000-4000-8000-0000000000b7", title: "Fine too", project: "app")
                try Retitler(store: store, codexHome: home).retitle(dryRun: false)
                #expect(try store.getTicket(id: blank.id).project == "ChatGPT" && store.getTicket(id: other.id).project == "app")
            }
        }
    }

    @Test func aChatOwnedByAnotherTicketIsNotStolenButTheTitleIsStillFixed() throws {
        try withCodexHome([thread: rolloutLines(prompt: ChatGPTFixtures.withRequest())]) { home in
            try withStore { store, _, _ in
                let owner = try store.createTicket(title: "Owner")
                try store.addLocation(
                    ticketId: owner.id, locator: .chatgptChat(.init(chatId: ChatGPTFixtures.conversationId, url: "https://chatgpt.com/c/\(ChatGPTFixtures.conversationId)")),
                    source: .manual, externalKey: "chatgpt:\(ChatGPTFixtures.conversationId)")
                let ticket = try headerTicket(store)
                let report = try Retitler(store: store, codexHome: home).retitle(dryRun: false)
                #expect(report.updated.first?.attachedChat == nil)
                #expect(try store.getTicket(id: ticket.id).title == "Write the release notes for version two")
                #expect(try store.location(byExternalKey: "chatgpt:\(ChatGPTFixtures.conversationId)")?.ticketId == owner.id)
            }
        }
    }

    @Test func rolloutLookupMatchesTheThreadSuffixOnlyAndNeverReadsOutsideSessions() throws {
        try withCodexHome([thread: rolloutLines(prompt: nil)]) { home in
            let rollout = CodexRollout(codexHome: home)
            #expect(rollout.file(forThread: thread)?.hasSuffix("-\(thread).jsonl") == true)
            #expect(rollout.file(forThread: "a1") == nil)  // 접미사가 `-`로 시작해야 한다
            #expect(rollout.file(forThread: "") == nil && rollout.file(forThread: "../../etc/passwd") == nil)
            #expect(CodexRollout(codexHome: home + "/missing").file(forThread: thread) == nil)
        }
    }

    @Test func remnantDetection() {
        #expect(Retitler.hasHeaderRemnant("## Referenced ChatGPT conversation: x"))
        #expect(Retitler.hasHeaderRemnant("  ## My request:"))
        #expect(Retitler.hasHeaderRemnant("Continuing from [A](chatgpt-conversation://x): do it"))
        #expect(!Retitler.hasHeaderRemnant("Continuing from the last session"))
        #expect(!Retitler.hasHeaderRemnant("Fix the flaky test"))
    }

    // MARK: 프로세스

    @Test func theCommandPrintsAPlanAndLeavesTheDatabaseAloneOnDryRun() throws {
        try withCodexHome([thread: rolloutLines(prompt: ChatGPTFixtures.withRequest())]) { home in
            try withStore { store, _, path in
                let ticket = try headerTicket(store)
                let environment = ["CODEX_HOME": home]

                let dry = jtm(["retitle", "--dry-run", "--json"], db: path, environment: environment)
                #expect(dry.status == 0 && dry.stderr.isEmpty, "\(dry.stderr)")
                #expect(dry.object?["ok"] as? Bool == true && dry.object?["dryRun"] as? Bool == true)
                let updated = dry.object?["updated"] as? [[String: Any]] ?? []
                #expect(updated.count == 1 && updated[0]["newTitle"] as? String == "Write the release notes for version two")
                #expect(updated[0]["newProject"] as? String == "ChatGPT" && updated[0]["attachedChat"] as? String == ChatGPTFixtures.conversationId)
                #expect(try store.getTicket(id: ticket.id).title == headerTitle)

                let text = jtm(["retitle", "--dry-run"], db: path, environment: environment)
                #expect(text.stdout.contains("would update 1 ticket(s) (dry run)") && text.stdout.contains("-> \"Write the release notes for version two\""), "\(text.stdout)")

                let real = jtm(["retitle"], db: path, environment: environment)
                #expect(real.status == 0 && real.stdout.contains("updated 1 ticket(s)"), "\(real.stdout)")
                #expect(try store.getTicket(id: ticket.id).project == "ChatGPT")
                #expect(jtm(["retitle"], db: path, environment: environment).stdout.contains("updated 0 ticket(s)"))
            }
        }
    }

    @Test func dryRunNeverCreatesTheDatabase() throws {
        let root = NSTemporaryDirectory() + "jtm-retitle-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let result = jtm(["retitle", "--dry-run"], db: root + "/nested/jtm.sqlite", environment: ["CODEX_HOME": root + "/none"])
        #expect(result.status == 0 && result.stdout.contains("would update 0"), "\(result.stdout)")
        #expect(!FileManager.default.fileExists(atPath: root))
    }
}
