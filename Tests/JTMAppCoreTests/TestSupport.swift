import Foundation
@testable import JTMCore

/// 테스트마다 고유한 임시 DB 경로. 끝나면 디렉터리를 지운다.
func withTempDB<T>(
    isolation: isolated (any Actor)? = #isolation, _ body: (String) async throws -> T
) async throws -> T {
    let directory = NSTemporaryDirectory() + "jtm-app-tests-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: directory) }
    return try await body(directory + "/nested/jtm.sqlite")
}

let epoch = Date(timeIntervalSince1970: 1_800_000_000)

func makeTicket(
    _ id: Int64, _ title: String = "t", status: TicketStatus = .active, reason: WaitingReason? = nil,
    project: String? = nil, next: String? = nil, activity: Date = epoch, kept: Bool = false, archivedAt: Date? = nil
) -> Ticket {
    Ticket(
        id: id, title: title, status: status, priority: nil, project: project, nextAction: next, note: nil,
        pinnedTitle: false, createdAt: activity, updatedAt: activity, lastActivityAt: activity,
        waitingReason: reason, endedAt: nil, kept: kept, archivedAt: archivedAt)
}

func makeLocation(_ id: Int64, ticket: Int64, _ locator: Locator, seen: Date = epoch) -> Location {
    Location(id: id, ticketId: ticket, locator: locator, source: .hook, externalKey: nil, lastSeenAt: seen)
}

func listing(_ ticket: Ticket, _ locations: [Location] = []) -> TicketListing {
    TicketListing(ticket: ticket, locations: locations)
}
