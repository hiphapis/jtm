import Foundation
import Testing
@testable import JTMAppCore
@testable import JTMCore

private final class RecordingRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _argvs: [[String]] = []
    var argvs: [[String]] { lock.withLock { _argvs } }
    func run(_ argv: [String], stdin: String?, timeout: TimeInterval) -> CommandResult {
        lock.withLock { _argvs.append(argv) }
        return CommandResult(exitCode: 0)
    }
}

private final class TestClockApp: @unchecked Sendable {
    var current = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

@Suite struct DatabaseBackendTests {
    @Test func loadCreatesAMissingDatabaseAndReadsWhatOthersWrite() async throws {
        try await withTempDB { path in
            let backend = DatabaseBackend(databasePath: path)
            #expect(try await backend.load(now: Date()).isEmpty)
            let writer = try Store(path: path)
            let ticket = try writer.createTicket(title: "hello", status: .waiting)
            try writer.addLocation(ticketId: ticket.id, locator: .url(.init(url: "https://example.com")), source: .manual)
            let listings = try await backend.load(now: Date())
            #expect(listings.map(\.ticket.title) == ["hello"] && listings[0].locations.count == 1)
        }
    }

    @Test func loadRecoversWithinTheSameCallWhenTheDatabaseFileWasReplaced() async throws {
        try await withTempDB { path in
            let backend = DatabaseBackend(databasePath: path)
            let first = try Store(path: path)
            _ = try first.createTicket(title: "old", status: .waiting)
            #expect(try await backend.load(now: Date()).map(\.ticket.title) == ["old"])
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
            let second = try Store(path: path)  // 초기화나 백업 복원처럼 새 파일이 생겼다
            _ = try second.createTicket(title: "new", status: .waiting)
            // 죽은 파일을 쥔 연결의 첫 읽기가 실패해도 호출 안에서 새 연결로 다시 읽는다.
            #expect(try await backend.load(now: Date()).map(\.ticket.title) == ["new"])
        }
    }

    @Test func writesPatchOnlyTheirOwnColumns() async throws {
        try await withTempDB { path in
            let backend = DatabaseBackend(databasePath: path)
            let store = try Store(path: path)
            let ticket = try store.createTicket(title: "auto", status: .waiting, project: "p", nextAction: "keep?")
            try await backend.setStatus(id: ticket.id, .done)
            var now = try store.getTicket(id: ticket.id)
            #expect(now.status == .done && now.nextAction == "keep?" && !now.pinnedTitle)

            try await backend.setNextAction(id: ticket.id, "  call back  ")
            now = try store.getTicket(id: ticket.id)
            #expect(now.nextAction == "call back")
            try await backend.setNextAction(id: ticket.id, "   ")
            #expect(try store.getTicket(id: ticket.id).nextAction == nil)

            try await backend.setTitle(id: ticket.id, " Mine ")
            now = try store.getTicket(id: ticket.id)
            #expect(now.title == "Mine" && now.pinnedTitle && now.project == "p")
        }
    }

    @Test func userEditsThroughTheBackendKeepTheTicketButDoneAndKeepToggleBehave() async throws {
        try await withTempDB { path in
            let backend = DatabaseBackend(databasePath: path)
            let store = try Store(path: path)
            func fresh() throws -> Int64 { try store.createTicket(title: "auto", status: .active).id }

            let done = try fresh()
            try await backend.setStatus(id: done, .done)
            #expect(try store.getTicket(id: done).kept == false)  // 완료는 유지가 아니다

            let status = try fresh()
            try await backend.setStatus(id: status, .blocked)
            let next = try fresh()
            try await backend.setNextAction(id: next, "call")
            let title = try fresh()
            try await backend.setTitle(id: title, "Mine")
            for id in [status, next, title] { #expect(try store.getTicket(id: id).kept) }

            let toggled = try fresh()
            try await backend.setKept(id: toggled, true)
            #expect(try store.getTicket(id: toggled).kept)
            try await backend.setKept(id: toggled, false)
            #expect(try store.getTicket(id: toggled).kept == false)
        }
    }

    @Test func ignoreRestoreAndArchiveStaleGoThroughTheStore() async throws {
        try await withTempDB { path in
            let backend = DatabaseBackend(databasePath: path)
            let clock = TestClockApp()
            let store = try Store(path: path, now: { clock.current })
            let ticket = try store.createTicket(title: "t", status: .active)
            try store.addLocation(
                ticketId: ticket.id, locator: .codexThread(.init(threadId: "c1")), source: .hook, externalKey: "codex:c1")
            let stale = try store.createTicket(title: "stale", status: .waiting)

            clock.advance(2 * 86_400)
            #expect(try await backend.archiveStale(now: clock.current) == 2)
            let listings = try await backend.load(now: clock.current)
            #expect(listings.filter { $0.ticket.archivedAt != nil }.count == 2)  // 보관함 티켓도 목록에 있다
            try await backend.restore(id: stale.id)
            let restored = try store.getTicket(id: stale.id)
            #expect(restored.kept && restored.archivedAt == nil)

            try await backend.ignore(id: ticket.id)
            #expect(try store.listTickets().map(\.id) == [stale.id])
            #expect(try store.ignoredSessions().map(\.externalKey) == ["codex:c1"])
            await #expect(throws: StoreError.self) { try await backend.ignore(id: ticket.id) }
        }
    }

    @Test func writingAMissingTicketThrows() async throws {
        try await withTempDB { path in
            let backend = DatabaseBackend(databasePath: path)
            _ = try Store(path: path)
            await #expect(throws: StoreError.self) { try await backend.setStatus(id: 999, .done) }
        }
    }

    @Test func goRunsTheResolverAndReportsClipboardFallbacks() async throws {
        try await withTempDB { path in
            let runner = RecordingRunner()
            let backend = DatabaseBackend(databasePath: path, makeResolver: { Resolver(runner: runner, orcaCommand: nil) })
            let store = try Store(path: path)
            let web = try store.createTicket(title: "web")
            try store.addLocation(ticketId: web.id, locator: .url(.init(url: "https://example.com/a")), source: .manual)
            let code = try store.createTicket(title: "code")
            try store.addLocation(ticketId: code.id, locator: .claudeCode(.init(sessionId: "s1", cwd: "/w")), source: .hook)
            let empty = try store.createTicket(title: "empty")

            let opened = await backend.go(id: web.id)
            #expect(opened.ok && !opened.copiedToClipboard)
            #expect(runner.argvs == [["open", "https://example.com/a"]])

            let copied = await backend.go(id: code.id)
            #expect(copied.ok && copied.copiedToClipboard)

            let none = await backend.go(id: empty.id)
            #expect(!none.ok && none.message == "이동할 위치가 없어요")
            let missing = await backend.go(id: 999)
            #expect(!missing.ok)
        }
    }
}

// MARK: 끝에서 끝까지: 다른 프로세스의 쓰기 → 감시 → 다시 읽기 → 목록 상태

@MainActor @Suite(.serialized) struct EndToEndReloadTests {
    /// `jtm add`/훅과 같은 방식(별도 커넥션이 커밋)으로 쓰고, 컨트롤러의 상태와 배지가 바뀔 때까지의 시간을 잰다. 인수 기준: < 1초.
    @Test func aWriteFromAnotherConnectionReachesTheBadgeWellUnderOneSecond() async throws {
        try await withTempDB { path in
            let seed = try Store(path: path)
            let controller = MenuController(backend: DatabaseBackend(databasePath: path))
            controller.start(databasePath: path, syncInterval: 3_600)
            defer { controller.stop() }
            try await Task.sleep(for: .milliseconds(400))
            #expect(controller.badgeCount == 0)

            var samples: [Double] = []
            for index in 1...10 {
                let started = ContinuousClock.now
                let hookLike = try Store(path: path)  // 매번 새 연결: 훅/CLI 프로세스처럼
                _ = try hookLike.createTicket(title: "waiting \(index)", status: .waiting)
                while controller.badgeCount != index, ContinuousClock.now - started < .seconds(3) {
                    try await Task.sleep(for: .milliseconds(2))
                }
                let elapsed = ContinuousClock.now - started
                samples.append(Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
                #expect(controller.badgeCount == index, "badge after write \(index)")
                try await Task.sleep(for: .milliseconds(100))
            }
            _ = seed
            let sorted = samples.sorted()
            print("E2E-LATENCY write→badge: n=\(samples.count) min=\(String(format: "%.1f", sorted.first!))ms median=\(String(format: "%.1f", sorted[sorted.count / 2]))ms max=\(String(format: "%.1f", sorted.last!))ms")
            #expect(sorted.last! < 1_000)
        }
    }
}
