import Foundation
import Testing
@testable import WWIAppCore
@testable import WWICore

/// 이 스위트의 테스트를 지정한 화면 언어로 돌린다(작업 단위 고정이라 병렬로 도는 다른 테스트에 영향이 없다).
/// 한국어 문구를 글자 그대로 단언하는 기존 테스트는 `.korean`으로 돌려서, 한국어 화면이 그대로임을 계속 확인한다.
struct LanguageTrait: SuiteTrait, TestTrait, TestScoping {
    let language: AppLanguage
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await L10n.$language.withValue(language) { try await function() }
    }
}

extension Trait where Self == LanguageTrait {
    static var korean: Self { LanguageTrait(language: .ko) }
    static var english: Self { LanguageTrait(language: .en) }
}

/// 테스트마다 고유한 임시 DB 경로. 끝나면 디렉터리를 지운다.
func withTempDB<T>(
    isolation: isolated (any Actor)? = #isolation, _ body: (String) async throws -> T
) async throws -> T {
    let directory = NSTemporaryDirectory() + "wwi-app-tests-\(UUID().uuidString)"
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
