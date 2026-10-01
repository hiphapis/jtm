import Foundation
import Testing
@testable import JTMCore

// jtm keep|unkeep|ignore|restore, jtm ls --archived: 실제 `jtm` 프로세스를 띄운다.

private let day: TimeInterval = 24 * 3_600

private func ids(_ result: CLIResult) -> [Int] { (result.array ?? []).compactMap { $0["id"] as? Int } }

@Suite struct CleanupCLITests {
    @Test func keepAndUnkeepToggleTheFlagAndPrintTheWriteEnvelope() throws {
        try withDatabase { db in
            _ = try Store(path: db).createTicket(title: "t", status: .active)
            let kept = jtm(["keep", "1", "--json"], db: db)
            #expect(kept.status == 0 && kept.object?["ok"] as? Bool == true && kept.object?["id"] as? Int == 1)
            #expect(jtm(["show", "1", "--json"], db: db).object?["kept"] as? Bool == true)
            #expect(jtm(["ls"], db: db).stdout.contains("★"))
            #expect(jtm(["unkeep", "1"], db: db).stdout.isEmpty)
            let shown = jtm(["show", "1", "--json"], db: db).object
            #expect(shown?["kept"] as? Bool == false && shown?["archivedAt"] is NSNull)
        }
    }

    @Test func unknownIdsFailWithAJSONErrorOnEveryNewCommand() throws {
        try withDatabase { db in
            for command in ["keep", "unkeep", "ignore", "restore"] {
                let result = jtm([command, "99", "--json"], db: db)
                #expect(result.status != 0 && result.object?["ok"] as? Bool == false, "\(command)")
                #expect((result.object?["error"] as? String)?.contains("not found") == true, "\(command)")
            }
        }
    }

    @Test func editingNextActionTitleNoteProjectOrStatusKeepsButDoneDoesNot() throws {
        try withDatabase { db in
            let store = try Store(path: db)
            for _ in 1...6 { _ = try store.createTicket(title: "t", status: .active) }
            #expect(jtm(["set", "1", "--next", "go"], db: db).status == 0)
            #expect(jtm(["set", "2", "--title", "T"], db: db).status == 0)
            #expect(jtm(["set", "3", "--note", "n"], db: db).status == 0)
            #expect(jtm(["set", "4", "--status", "blocked"], db: db).status == 0)
            #expect(jtm(["set", "5", "--status", "done"], db: db).status == 0)
            #expect(jtm(["done", "6"], db: db).status == 0)
            let kept = (try Store(path: db).listTickets()).sorted { $0.id < $1.id }.map(\.kept)
            #expect(kept == [true, true, true, true, false, false])
            // project와 priority 편집도 사용자가 손댄 것이다(자동 수집은 이 경로를 쓰지 않는다).
            let project = jtm(["set", "5", "--project", "p"], db: db)
            #expect(project.status == 0)
            #expect(try Store(path: db).getTicket(id: 5).kept == true)
            let priority = jtm(["set", "6", "--priority", "1"], db: db)
            #expect(priority.status == 0)
            #expect(try Store(path: db).getTicket(id: 6).kept == true)
        }
    }

    @Test func addCreatesAKeptTicket() throws {
        try withDatabase { db in
            #expect(jtm(["add", "my task"], db: db).status == 0)
            #expect(jtm(["show", "1", "--json"], db: db).object?["kept"] as? Bool == true)
        }
    }

    @Test func ignoreDeletesTheTicketAndRemembersItsSessions() throws {
        try withDatabase { db in
            let store = try Store(path: db)
            let ticket = try store.createTicket(title: "t", status: .active)
            try store.addLocation(ticketId: ticket.id, locator: .claudeCode(.init(sessionId: "s1", cwd: "/w")), source: .hook, externalKey: "claude:s1")
            try store.addLocation(ticketId: ticket.id, locator: .orcaTerminal(.init(terminalHandle: "h", tabId: "tab-1")), source: .hook, externalKey: "orca-tab:tab-1")
            let result = jtm(["ignore", "1", "--json"], db: db)
            #expect(result.status == 0 && result.object?["ok"] as? Bool == true)
            #expect(result.object?["ignoredSessions"] as? [String] == ["claude:s1"])
            #expect(jtm(["ls", "--all", "--json"], db: db).array?.isEmpty == true)
            let reopened = try Store(path: db)
            let ignored = try reopened.ignoredSessions()
            #expect(ignored.map(\.externalKey) == ["claude:s1"] && ignored.first?.reason == "user-ignored")
            // 같은 세션의 훅은 더는 티켓을 만들지 않는다.
            let hook = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/w","prompt":"again"}"#.utf8)
            #expect(jtm(["ingest", "claude"], db: db, stdin: hook).status == 0)
            #expect(jtm(["ls", "--all", "--json"], db: db).array?.isEmpty == true)
            // 새 세션은 새 티켓이 된다.
            let fresh = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s2","cwd":"/w","prompt":"new"}"#.utf8)
            #expect(jtm(["ingest", "claude"], db: db, stdin: fresh).status == 0)
            #expect(jtm(["ls", "--all", "--json"], db: db).array?.count == 1)
        }
    }

    @Test func lsHidesTheArchiveByDefaultAndShowsItWithArchivedOrAll() throws {
        try withDatabase { db in
            let clock = TestClock()
            let store = try Store(path: db, now: { clock.current })
            _ = try store.createTicket(title: "old", status: .waiting)
            _ = try store.createTicket(title: "old done", status: .done)
            clock.advance(2 * day)
            _ = try store.createTicket(title: "fresh", status: .active)
            #expect(try store.archiveStale() == 1)

            #expect(ids(jtm(["ls", "--json"], db: db)) == [3])
            #expect(ids(jtm(["ls", "--archived", "--json"], db: db)) == [1])
            #expect(ids(jtm(["ls", "--all", "--json"], db: db)).sorted() == [1, 2, 3])
            #expect(ids(jtm(["ls", "--status", "waiting", "--json"], db: db)).isEmpty)  // --status도 보관함은 숨긴다
            #expect(ids(jtm(["ls", "--archived", "--status", "waiting", "--json"], db: db)) == [1])
            let conflict = jtm(["ls", "--all", "--archived", "--json"], db: db)
            #expect(conflict.status == 64 && conflict.object?["ok"] as? Bool == false)
            let shown = jtm(["show", "1", "--json"], db: db).object
            #expect(shown?["archivedAt"] is String && shown?["status"] as? String == "waiting")
        }
    }

    @Test func restoreBringsAnArchivedTicketBackAsKept() throws {
        try withDatabase { db in
            let clock = TestClock()
            let store = try Store(path: db, now: { clock.current })
            _ = try store.createTicket(title: "old", status: .active)
            clock.advance(2 * day)
            try store.archiveStale()
            #expect(jtm(["restore", "1", "--json"], db: db).object?["ok"] as? Bool == true)
            let shown = jtm(["show", "1", "--json"], db: db).object
            #expect(shown?["kept"] as? Bool == true && shown?["archivedAt"] is NSNull)
            #expect(ids(jtm(["ls", "--json"], db: db)) == [1])
        }
    }

    @Test func ignoredListsSessionsAndUnignoreLetsThemBackIn() throws {
        try withDatabase { db in
            let store = try Store(path: db)
            try store.ignoreSession("codex:c1", reason: "codex-internal-nofile")
            try store.ignoreSession("claude:s1", reason: "user-ignored")
            let listed = jtm(["ignored", "--json"], db: db)
            #expect(listed.status == 0)
            let rows = listed.array ?? []
            #expect(rows.map { $0["key"] as? String } == ["claude:s1", "codex:c1"])
            #expect(rows.last?["reason"] as? String == "codex-internal-nofile" && rows.last?["createdAt"] is String)
            let text = jtm(["ignored"], db: db).stdout
            #expect(text.contains("codex:c1") && text.contains("codex-internal-nofile"))

            let removed = jtm(["unignore", "codex:c1", "--json"], db: db)
            #expect(removed.status == 0 && removed.object?["ok"] as? Bool == true && removed.object?["key"] as? String == "codex:c1")
            #expect(try Store(path: db).ignoredSessions().map(\.externalKey) == ["claude:s1"])
            let again = jtm(["unignore", "codex:c1", "--json"], db: db)
            #expect(again.status != 0 && again.object?["ok"] as? Bool == false)
            #expect((again.object?["error"] as? String)?.contains("not in the ignore list") == true)
        }
    }
}
