import Foundation
import Testing
@testable import WWICore

@Suite struct StoreReadOnlyTests {
    @Test func menuListingGroupsLocationsAndLimitsDoneTickets() throws {
        try withStore { store, clock, _ in
            let waiting = try store.createTicket(title: "w", status: .waiting)
            let active = try store.createTicket(title: "a", status: .active)
            let oldDone = try store.createTicket(title: "old", status: .done)
            clock.advance(3 * 3_600)
            let freshDone = try store.createTicket(title: "fresh", status: .done)
            try store.addLocation(ticketId: waiting.id, locator: .url(.init(url: "https://a.example")), source: .manual, externalKey: "u1")
            try store.addLocation(ticketId: waiting.id, locator: .orcaTerminal(.init(terminalHandle: "t")), source: .hook, externalKey: "o1")
            try store.addLocation(ticketId: oldDone.id, locator: .url(.init(url: "https://b.example")), source: .manual, externalKey: "u2")

            let listing = try store.menuListing(doneSince: clock.current.addingTimeInterval(-3_600))
            #expect(listing.map(\.ticket.id) == [waiting.id, active.id, freshDone.id])
            #expect(listing[0].locations.map(\.kind) == [.url, .orcaTerminal])
            #expect(listing[1].locations.isEmpty)
        }
    }

    @Test func readOnlyStoreSeesWritesButCannotWrite() throws {
        try withStore { writer, _, path in
            let reader = try Store(readOnlyPath: path)
            #expect(try reader.menuListing(doneSince: .distantPast).isEmpty)
            let ticket = try writer.createTicket(title: "x", status: .waiting)
            #expect(try reader.menuListing(doneSince: .distantPast).map(\.ticket.id) == [ticket.id])
            #expect(throws: StoreError.self) { try reader.patchTicket(id: ticket.id, TicketPatch(status: .done)) }
            #expect(try writer.getTicket(id: ticket.id).status == .waiting)
        }
    }

    @Test func readOnlyStoreNeverCreatesOrMigratesTheDatabase() throws {
        let directory = NSTemporaryDirectory() + "wwi-tests-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/jtm.sqlite"
        #expect(throws: StoreError.self) { try Store(readOnlyPath: path) }
        #expect(!FileManager.default.fileExists(atPath: path))
        FileManager.default.createFile(atPath: path, contents: Data())  // 빈 파일 = 아직 스키마 없음
        #expect(throws: StoreError.self) { try Store(readOnlyPath: path) }
    }

    @Test func readerIsNotBlockedByAnOpenWriteTransaction() throws {
        try withStore { writer, _, path in
            _ = try writer.createTicket(title: "seed")
            let reader = try Store(readOnlyPath: path)
            try writer.transaction {
                _ = try writer.createTicket(title: "uncommitted")
                // 쓰기 트랜잭션이 열려 있어도 읽기는 기다리지 않고 커밋된 것만 본다.
                #expect(try reader.menuListing(doneSince: .distantPast).map(\.ticket.title) == ["seed"])
            }
            #expect(try reader.menuListing(doneSince: .distantPast).count == 2)
        }
    }

    @Test func dataVersionChangesOnlyWhenAnotherConnectionCommits() throws {
        try withStore { writer, _, path in
            let reader = try Store(readOnlyPath: path)
            let before = try reader.dataVersion()
            _ = try reader.menuListing(doneSince: .distantPast)
            #expect(try reader.dataVersion() == before)
            _ = try writer.createTicket(title: "x")
            #expect(try reader.dataVersion() != before)
        }
    }
}
