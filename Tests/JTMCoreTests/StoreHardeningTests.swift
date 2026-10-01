import Foundation
import SQLite3
import Testing
@testable import JTMCore

private final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func add(_ message: String) { lock.lock(); messages.append(message); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return messages }
}

@Suite struct MigrationRaceTests {
    /// B1 회귀: 새 DB를 여러 스레드가 동시에 처음 열어도 실패가 없어야 한다.
    @Test func concurrentFirstOpenOnFreshDatabaseNeverFails() {
        let failures = FailureLog()
        for round in 0..<25 {
            let directory = NSTemporaryDirectory() + "jtm-race-\(UUID().uuidString)"
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let path = directory + "/jtm.sqlite"
            DispatchQueue.concurrentPerform(iterations: 8) { worker in
                do {
                    let store = try Store(path: path)
                    _ = try store.listTickets()
                } catch {
                    failures.add("round \(round) worker \(worker): \(error)")
                }
            }
        }
        #expect(failures.all.isEmpty, "\(failures.all.prefix(3))")
    }

    @Test func concurrentWritersAllLandOnWarmDatabase() throws {
        try withStore { _, _, path in
            let failures = FailureLog()
            DispatchQueue.concurrentPerform(iterations: 16) { worker in
                do {
                    let store = try Store(path: path)
                    _ = try store.createTicket(title: "t\(worker)")
                } catch {
                    failures.add("worker \(worker): \(error)")
                }
            }
            #expect(failures.all.isEmpty, "\(failures.all.prefix(3))")
            let landed = try Store(path: path).listTickets().count
            #expect(landed == 16)
        }
    }

    @Test func openFailureThrowsInsteadOfCrashing() {
        // 파일이 있어야 할 자리에 디렉터리가 있으면 open이 실패한다(S1: 실패 경로에서 이중 close 금지).
        let directory = NSTemporaryDirectory() + "jtm-open-fail-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try? FileManager.default.createDirectory(atPath: directory + "/jtm.sqlite", withIntermediateDirectories: true)
        #expect(throws: StoreError.self) { try Store(path: directory + "/jtm.sqlite") }
    }

    @Test func rejectsDatabaseFromNewerSchema() throws {
        try withStore { _, _, path in
            rawSQL(path, "PRAGMA user_version = 9") { _ in }
            #expect(throws: StoreError.self) { try Store(path: path) }
        }
    }
}

@Suite struct TransactionTests {
    @Test func rollsBackEverythingWhenBodyThrows() throws {
        try withStore { store, _, _ in
            struct Boom: Error {}
            #expect(throws: Boom.self) {
                try store.transaction {
                    let ticket = try store.createTicket(title: "doomed")
                    try store.addLocation(ticketId: ticket.id, locator: .url(.init(url: "u")), source: .manual)
                    throw Boom()
                }
            }
            let remaining = try store.listTickets()
            #expect(remaining.isEmpty)
        }
    }

    @Test func commitsAndNestedCallsJoinOuterTransaction() throws {
        try withStore { store, _, _ in
            let ticket = try store.transaction {
                try store.transaction { try store.createTicket(title: "kept") }
            }
            #expect(try store.getTicket(id: ticket.id).title == "kept")
        }
    }

    @Test func failedInnerStatementRollsBackOuterTicket() throws {
        try withStore { store, _, _ in
            #expect(throws: StoreError.self) {
                try store.transaction {
                    _ = try store.createTicket(title: "orphan")
                    try store.addLocation(ticketId: 999, locator: .url(.init(url: "u")), source: .manual)
                }
            }
            let remaining = try store.listTickets()
            #expect(remaining.isEmpty)
        }
    }
}

@Suite struct PatchTests {
    @Test func patchOnlyTouchesSuppliedColumns() throws {
        try withStore { store, clock, _ in
            let ticket = try store.createTicket(title: "t", project: "p", nextAction: "n", note: "keep")
            clock.advance(60)
            let patched = try store.patchTicket(id: ticket.id, TicketPatch(nextAction: .some("new")))
            #expect(patched.nextAction == "new")
            #expect(patched.title == "t" && patched.project == "p" && patched.note == "keep")
            #expect(patched.status == .inbox)
            #expect(patched.updatedAt == clock.current)
            #expect(patched.lastActivityAt == ticket.lastActivityAt)
        }
    }

    /// S2: 오래된 스냅샷을 든 쪽이 다른 프로세스의 변경을 되돌리지 않는다.
    @Test func patchDoesNotRevertConcurrentChangeToOtherColumns() throws {
        try withStore { store, _, path in
            let ticket = try store.createTicket(title: "t", status: .waiting)
            let other = try Store(path: path)
            try other.patchTicket(id: ticket.id, TicketPatch(status: .active))
            try store.patchTicket(id: ticket.id, TicketPatch(note: .some("hello")))
            let final = try store.getTicket(id: ticket.id)
            #expect(final.status == .active)
            #expect(final.note == "hello")
        }
    }

    @Test func patchCanClearOptionalColumns() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "t", priority: 3, project: "p", nextAction: "n", note: "x")
            let cleared = try store.patchTicket(
                id: ticket.id,
                TicketPatch(priority: .some(nil), project: .some(nil), nextAction: .some(nil), note: .some(nil)))
            #expect(cleared.priority == nil && cleared.project == nil && cleared.nextAction == nil && cleared.note == nil)
        }
    }

    @Test func statusChangeBumpsLastActivityButOtherFieldsDoNot() throws {
        try withStore { store, clock, _ in
            let ticket = try store.createTicket(title: "t")
            clock.advance(100)
            let noted = try store.patchTicket(id: ticket.id, TicketPatch(project: .some("p")))
            #expect(noted.lastActivityAt == ticket.lastActivityAt)
            #expect(noted.updatedAt == clock.current)
            clock.advance(100)
            let done = try store.patchTicket(id: ticket.id, TicketPatch(status: .done))
            #expect(done.lastActivityAt == clock.current)
        }
    }

    @Test func emptyPatchOnlyBumpsUpdatedAt() throws {
        try withStore { store, clock, _ in
            let ticket = try store.createTicket(title: "t")
            clock.advance(30)
            let touched = try store.patchTicket(id: ticket.id)
            #expect(touched.updatedAt == clock.current)
            #expect(touched.lastActivityAt == ticket.lastActivityAt)
        }
    }

    @Test func patchUnknownTicketThrows() throws {
        try withStore { store, _, _ in
            #expect(throws: StoreError.self) { try store.patchTicket(id: 42) }
            #expect(throws: StoreError.self) { try store.touchActivity(id: 42) }
        }
    }

    @Test func touchActivityNeverMovesBackwards() throws {
        try withStore { store, clock, _ in
            let ticket = try store.createTicket(title: "t")
            clock.advance(100)
            let forward = try store.touchActivity(id: ticket.id)
            #expect(forward.lastActivityAt == clock.current)
            let stale = try store.touchActivity(id: ticket.id, at: ticket.createdAt)
            #expect(stale.lastActivityAt == clock.current)
        }
    }
}

@Suite struct TitlePinTests {
    @Test func autoUpdateChangesUnpinnedTitle() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "auto v1")
            #expect(try store.autoUpdateTitle(id: ticket.id, title: "auto v2"))
            #expect(try store.getTicket(id: ticket.id).title == "auto v2")
        }
    }

    @Test func autoUpdateIsNoOpWhenPinned() throws {
        try withStore { store, clock, _ in
            let ticket = try store.createTicket(title: "mine", pinnedTitle: true)
            clock.advance(10)
            #expect(try store.autoUpdateTitle(id: ticket.id, title: "auto") == false)
            let after = try store.getTicket(id: ticket.id)
            #expect(after.title == "mine")
            #expect(after.updatedAt == ticket.updatedAt)
        }
    }

    @Test func patchPinAndUnpinControlsAutoUpdate() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "t")
            try store.patchTicket(id: ticket.id, TicketPatch(title: "typed", pinnedTitle: true))
            #expect(try store.autoUpdateTitle(id: ticket.id, title: "auto") == false)
            try store.patchTicket(id: ticket.id, TicketPatch(pinnedTitle: false))
            #expect(try store.autoUpdateTitle(id: ticket.id, title: "auto"))
            #expect(try store.getTicket(id: ticket.id).title == "auto")
        }
    }

    @Test func autoUpdateIgnoresBlankTitleAndUnknownTicket() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "keep")
            #expect(try store.autoUpdateTitle(id: ticket.id, title: "   ") == false)
            #expect(throws: StoreError.self) { try store.autoUpdateTitle(id: 99, title: "x") }
        }
    }
}

@Suite struct ExternalKeyTests {
    @Test func upsertTicketAndLocationCreatesOnce() throws {
        try withStore { store, _, _ in
            var created: [Bool] = []
            for _ in 0..<10 {
                let result = try store.upsertTicketAndLocation(
                    externalKey: "claude:s1", locator: .claudeCode(.init(sessionId: "s1", cwd: "/w")),
                    source: .hook, newTicket: NewTicket(title: "session s1"))
                created.append(result.created)
            }
            #expect(created == [true] + Array(repeating: false, count: 9))
            let tickets = try store.listTickets()
            #expect(tickets.count == 1)
            #expect(try store.locations(ticketId: tickets[0].id).count == 1)
        }
    }

    @Test func concurrentUpsertsOfSameKeyYieldOneTicket() throws {
        try withStore { _, _, path in
            let failures = FailureLog()
            DispatchQueue.concurrentPerform(iterations: 12) { worker in
                do {
                    let store = try Store(path: path)
                    _ = try store.upsertTicketAndLocation(
                        externalKey: "claude:same", locator: .claudeCode(.init(sessionId: "same", cwd: "/w")),
                        source: .hook, newTicket: NewTicket(title: "t\(worker)"))
                } catch {
                    failures.add("\(error)")
                }
            }
            #expect(failures.all.isEmpty, "\(failures.all.prefix(3))")
            let tickets = try Store(path: path).listTickets()
            #expect(tickets.count == 1)
        }
    }

    @Test func upsertKeepsOriginalSourceAndTicketButRefreshesLocatorAndLastSeen() throws {
        try withStore { store, clock, _ in
            let first = try store.upsertTicketAndLocation(
                externalKey: "orca-tab:t1", locator: .orcaTerminal(.init(terminalHandle: "old")),
                source: .hook, newTicket: NewTicket(title: "t"))
            clock.advance(30)
            let second = try store.upsertTicketAndLocation(
                externalKey: "orca-tab:t1", locator: .orcaTerminal(.init(terminalHandle: "new")),
                source: .orcaSync, newTicket: NewTicket(title: "other"))
            #expect(second.ticket.id == first.ticket.id)
            #expect(second.location.id == first.location.id)
            #expect(second.location.source == .hook)
            #expect(second.location.locator == .orcaTerminal(.init(terminalHandle: "new")))
            #expect(second.location.lastSeenAt == clock.current)
            #expect(second.ticket.title == "t")
        }
    }

    @Test func upsertLocationByKeyKeepsOriginalSource() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "t")
            let a = try store.upsertLocation(
                byExternalKey: "k", ticketId: ticket.id, locator: .url(.init(url: "u1")), source: .hook)
            let b = try store.upsertLocation(
                byExternalKey: "k", ticketId: ticket.id, locator: .url(.init(url: "u2")), source: .orcaSync)
            #expect(a.id == b.id && b.source == .hook)
        }
    }

    @Test func lookupByExternalKey() throws {
        try withStore { store, _, _ in
            #expect(try store.location(byExternalKey: "nope") == nil)
            let ticket = try store.createTicket(title: "t")
            let added = try store.addLocation(
                ticketId: ticket.id, locator: .codexThread(.init(threadId: "x")), source: .hook, externalKey: "codex:x")
            #expect(try store.location(byExternalKey: "codex:x") == added)
        }
    }

    @Test func emptyKeyIsRejected() throws {
        try withStore { store, _, _ in
            #expect(throws: StoreError.self) {
                try store.upsertTicketAndLocation(
                    externalKey: "", locator: .url(.init(url: "u")), source: .hook, newTicket: NewTicket(title: "t"))
            }
            let remaining = try store.listTickets()
            #expect(remaining.isEmpty)
        }
    }
}

@Suite struct LenientReadTests {
    @Test func listSkipsRowsWithUnknownStatusAndWarns() throws {
        let warnings = FailureLog()
        let directory = NSTemporaryDirectory() + "jtm-lenient-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/jtm.sqlite"
        let store = try Store(path: path, onWarning: { warnings.add($0) })
        let good = try store.createTicket(title: "good")
        let bad = try store.createTicket(title: "bad")
        rawSQL(path, "UPDATE tickets SET status = 'from-the-future' WHERE id = \(bad.id)") { _ in }

        #expect(try store.listTickets().map(\.id) == [good.id])
        #expect(warnings.all.count == 1 && warnings.all[0].contains("ticket \(bad.id)"))
    }

    @Test func locationsSkipUnknownKind() throws {
        let warnings = FailureLog()
        let directory = NSTemporaryDirectory() + "jtm-lenient-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/jtm.sqlite"
        let store = try Store(path: path, onWarning: { warnings.add($0) })
        let ticket = try store.createTicket(title: "t")
        let ok = try store.addLocation(ticketId: ticket.id, locator: .url(.init(url: "u")), source: .manual)
        let odd = try store.addLocation(ticketId: ticket.id, locator: .url(.init(url: "v")), source: .manual)
        rawSQL(path, "UPDATE locations SET kind = 'hologram' WHERE id = \(odd.id)") { _ in }

        #expect(try store.locations(ticketId: ticket.id) == [ok])
        #expect(warnings.all.count == 1)
    }
}
