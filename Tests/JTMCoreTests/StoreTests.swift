import Foundation
import SQLite3
import Testing
@testable import JTMCore

@Suite struct StoreTests {
    // MARK: Setup / schema

    @Test func createsParentDirectoryAndMigratesToV3InWALMode() throws {
        try withStore { _, _, path in
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(rawSQL(path, "PRAGMA user_version") { sqlite3_column_int($0, 0) } == 6)
            #expect(rawSQL(path, "PRAGMA journal_mode") { String(cString: sqlite3_column_text($0, 0)) } == "wal")
        }
    }

    @Test func reopeningKeepsDataAndDoesNotRemigrate() throws {
        try withStore { store, clock, path in
            let created = try store.createTicket(title: "keep me")
            let reopened = try Store(path: path, now: { clock.current })
            #expect(try reopened.getTicket(id: created.id) == created)
        }
    }

    @Test func deletingTicketCascadesToLocations() throws {
        try withStore { store, _, path in
            let ticket = try store.createTicket(title: "t")
            try store.addLocation(ticketId: ticket.id, locator: .url(.init(url: "https://a.example")), source: .manual)
            rawSQL(path, "DELETE FROM tickets WHERE id = \(ticket.id)", foreignKeys: true) { _ in }
            #expect(try store.locations(ticketId: ticket.id).isEmpty)
        }
    }

    // MARK: Tickets

    @Test func createTicketDefaults() throws {
        try withStore { store, clock, _ in
            let ticket = try store.createTicket(title: "write spec")
            #expect(ticket.id == 1)
            #expect(ticket.status == .inbox)
            #expect(ticket.pinnedTitle == false)
            #expect(ticket.priority == nil && ticket.project == nil && ticket.nextAction == nil && ticket.note == nil)
            #expect(ticket.createdAt == clock.current)
            #expect(ticket.updatedAt == clock.current)
            #expect(ticket.lastActivityAt == clock.current)
        }
    }

    @Test func createTicketStoresOptionalFields() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(
                title: "t", status: .waiting, priority: 2, project: "jtm", nextAction: "reply", note: "n")
            #expect(try store.getTicket(id: ticket.id) == ticket)
            #expect(ticket.status == .waiting && ticket.priority == 2 && ticket.project == "jtm")
            #expect(ticket.nextAction == "reply" && ticket.note == "n")
        }
    }

    @Test func getUnknownTicketThrows() throws {
        try withStore { store, _, _ in
            #expect(throws: StoreError.self) { try store.getTicket(id: 99) }
        }
    }

    @Test func updateTicketPersistsFieldsAndBumpsUpdatedAtOnly() throws {
        try withStore { store, clock, _ in
            var ticket = try store.createTicket(title: "old")
            clock.advance(60)
            ticket.title = "new"
            ticket.status = .done
            ticket.priority = 1
            ticket.pinnedTitle = true
            ticket.nextAction = "ship"
            let updated = try store.updateTicket(ticket)
            #expect(updated.title == "new" && updated.status == .done && updated.priority == 1)
            #expect(updated.pinnedTitle && updated.nextAction == "ship")
            #expect(updated.updatedAt == clock.current)
            #expect(updated.lastActivityAt == ticket.lastActivityAt)
            #expect(updated.createdAt == ticket.createdAt)
        }
    }

    @Test func updateCanClearOptionalFields() throws {
        try withStore { store, _, _ in
            var ticket = try store.createTicket(title: "t", project: "p", nextAction: "n")
            ticket.project = nil
            ticket.nextAction = nil
            let updated = try store.updateTicket(ticket)
            #expect(updated.project == nil && updated.nextAction == nil)
        }
    }

    @Test func updateUnknownTicketThrows() throws {
        try withStore { store, _, _ in
            var ticket = try store.createTicket(title: "t")
            ticket.id = 99
            #expect(throws: StoreError.self) { try store.updateTicket(ticket) }
        }
    }

    // MARK: Listing

    @Test func listOrdersByStatusGroupThenRecentActivity() throws {
        try withStore { store, clock, _ in
            for (title, status) in [
                ("done-old", TicketStatus.done), ("blocked", .blocked), ("inbox-old", .inbox),
                ("active", .active), ("waiting", .waiting), ("inbox-new", .inbox), ("done-new", .done),
            ] {
                _ = try store.createTicket(title: title, status: status)
                clock.advance(10)
            }
            let titles = try store.listTickets().map(\.title)
            #expect(titles == ["waiting", "active", "inbox-new", "inbox-old", "blocked", "done-new", "done-old"])
        }
    }

    @Test func listBreaksActivityTiesByNewestId() throws {
        try withStore { store, _, _ in
            _ = try store.createTicket(title: "first")
            _ = try store.createTicket(title: "second")
            #expect(try store.listTickets().map(\.title) == ["second", "first"])
        }
    }

    @Test func listFiltersByStatuses() throws {
        try withStore { store, _, _ in
            _ = try store.createTicket(title: "a", status: .active)
            _ = try store.createTicket(title: "b", status: .done)
            _ = try store.createTicket(title: "c", status: .waiting)
            #expect(try store.listTickets(statuses: [.active, .waiting]).map(\.title) == ["c", "a"])
            #expect(try store.listTickets(statuses: [.done]).map(\.title) == ["b"])
            #expect(try store.listTickets(statuses: []).isEmpty)
        }
    }

    // MARK: Locations

    @Test func addLocationStoresPayloadAndListsInInsertionOrder() throws {
        try withStore { store, clock, _ in
            let ticket = try store.createTicket(title: "t")
            let terminal = Locator.orcaTerminal(.init(terminalHandle: "term_x", tabId: "tab-1"))
            let first = try store.addLocation(
                ticketId: ticket.id, locator: terminal, source: .manual, externalKey: "orca-tab:tab-1")
            let second = try store.addLocation(
                ticketId: ticket.id, locator: .url(.init(url: "https://example.com")), source: .manual)
            let stored = try store.locations(ticketId: ticket.id)
            #expect(stored == [first, second])
            #expect(first.kind == .orcaTerminal && first.locator == terminal)
            #expect(first.externalKey == "orca-tab:tab-1" && second.externalKey == nil)
            #expect(first.lastSeenAt == clock.current)
        }
    }

    @Test func locationsAreScopedToTicket() throws {
        try withStore { store, _, _ in
            let a = try store.createTicket(title: "a")
            let b = try store.createTicket(title: "b")
            try store.addLocation(ticketId: a.id, locator: .codexThread(.init(threadId: "1")), source: .hook)
            #expect(try store.locations(ticketId: a.id).count == 1)
            #expect(try store.locations(ticketId: b.id).isEmpty)
        }
    }

    @Test func addLocationRejectsUnknownTicket() throws {
        try withStore { store, _, _ in
            #expect(throws: StoreError.self) {
                try store.addLocation(ticketId: 42, locator: .url(.init(url: "u")), source: .manual)
            }
        }
    }

    @Test func externalKeyIsUniqueForAddLocation() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "t")
            let locator = Locator.claudeCode(.init(sessionId: "s1", cwd: "/tmp"))
            try store.addLocation(ticketId: ticket.id, locator: locator, source: .hook, externalKey: "claude:s1")
            #expect(throws: StoreError.self) {
                try store.addLocation(ticketId: ticket.id, locator: locator, source: .hook, externalKey: "claude:s1")
            }
        }
    }

    @Test func upsertInsertsThenUpdatesSameRow() throws {
        try withStore { store, clock, _ in
            let ticket = try store.createTicket(title: "t")
            let other = try store.createTicket(title: "other")
            let inserted = try store.upsertLocation(
                byExternalKey: "claude:s1", ticketId: ticket.id,
                locator: .claudeCode(.init(sessionId: "s1", cwd: "/a")), source: .hook)
            clock.advance(30)
            let updated = try store.upsertLocation(
                byExternalKey: "claude:s1", ticketId: other.id,
                locator: .claudeCode(.init(sessionId: "s1", cwd: "/b")), source: .hook)

            #expect(updated.id == inserted.id)
            #expect(updated.ticketId == ticket.id)
            #expect(updated.locator == .claudeCode(.init(sessionId: "s1", cwd: "/b")))
            #expect(updated.lastSeenAt == clock.current)
            #expect(inserted.lastSeenAt < updated.lastSeenAt)
            #expect(try store.locations(ticketId: ticket.id).count == 1)
            #expect(try store.locations(ticketId: other.id).isEmpty)
        }
    }

    @Test func upsertWithDifferentKeysCreatesSeparateLocations() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "t")
            try store.upsertLocation(
                byExternalKey: "claude:s1", ticketId: ticket.id, locator: .claudeCode(.init(sessionId: "s1", cwd: "/")), source: .hook)
            try store.upsertLocation(
                byExternalKey: "codex:s2", ticketId: ticket.id, locator: .codexThread(.init(threadId: "s2")), source: .hook)
            #expect(try store.locations(ticketId: ticket.id).count == 2)
        }
    }

    @Test func upsertRejectsEmptyKey() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "t")
            #expect(throws: StoreError.self) {
                try store.upsertLocation(
                    byExternalKey: "", ticketId: ticket.id, locator: .url(.init(url: "u")), source: .hook)
            }
        }
    }

    @Test func locationsPrimaryPrefersOrcaTerminal() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "t")
            try store.addLocation(ticketId: ticket.id, locator: .url(.init(url: "https://a.example")), source: .manual)
            #expect(try store.locations(ticketId: ticket.id).primary?.kind == .url)
            try store.addLocation(
                ticketId: ticket.id, locator: .orcaTerminal(.init(terminalHandle: "term_x")), source: .manual)
            #expect(try store.locations(ticketId: ticket.id).primary?.kind == .orcaTerminal)
        }
    }
}
