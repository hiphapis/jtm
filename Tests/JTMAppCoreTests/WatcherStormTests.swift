import Foundation
import Testing
@testable import JTMAppCore
@testable import JTMCore

/// `load` 호출 수를 세는 백엔드(실제 DB를 읽는다).
private final class CountingBackend: MenuBackend, @unchecked Sendable {
    private let inner: DatabaseBackend
    private let lock = NSLock()
    private var loads = 0
    var loadCount: Int { lock.withLock { loads } }

    init(databasePath: String) { inner = DatabaseBackend(databasePath: databasePath) }

    func load(now: Date) async throws -> [TicketListing] {
        lock.withLock { loads += 1 }
        return try await inner.load(now: now)
    }
    func setStatus(id: Int64, _ status: TicketStatus) async throws { try await inner.setStatus(id: id, status) }
    func setNextAction(id: Int64, _ text: String?) async throws { try await inner.setNextAction(id: id, text) }
    func setTitle(id: Int64, _ title: String) async throws { try await inner.setTitle(id: id, title) }
    func go(id: Int64) async -> GoOutcome { await inner.go(id: id) }
}

@Suite(.serialized) struct WatcherStormTests {
    /// 훅 폭주 재현: 30ms 간격으로 3초 동안 쓰면 목록을 몇 번 다시 읽는가(P3-R S3 측정).
    private func storm(popoverOpen: Bool) async throws -> (writes: Int, reloads: Int, seconds: Double) {
        try await withTempDB { path in
            let writer = try Store(path: path)
            let ticket = try writer.createTicket(title: "t", status: .active)
            let backend = CountingBackend(databasePath: path)
            let controller = await MainActor.run { MenuController(backend: backend) }
            await MainActor.run {
                if popoverOpen { controller.popoverOpened() }
                controller.start(databasePath: path, syncInterval: 3_600)
            }
            try await Task.sleep(for: .milliseconds(600))  // 시작 직후의 읽기가 가라앉을 시간
            let baseline = backend.loadCount

            let started = ContinuousClock.now
            var writes = 0
            let statuses: [TicketStatus] = [.waiting, .active]
            while ContinuousClock.now - started < .seconds(3) {
                try writer.patchTicket(id: ticket.id, TicketPatch(status: statuses[writes % 2]))
                writes += 1
                try await Task.sleep(for: .milliseconds(30))
            }
            let stormEnd = ContinuousClock.now
            let reloadsDuringStorm = backend.loadCount - baseline
            try await Task.sleep(for: .milliseconds(1_500))  // 마지막 쓰기 뒤 알림이 잠잠해지는 데 필요한 시간
            let total = backend.loadCount - baseline
            await MainActor.run { controller.stop() }
            let seconds = Double((stormEnd - started).components.seconds) + Double((stormEnd - started).components.attoseconds) / 1e18
            print("STORM open=\(popoverOpen) writes=\(writes) reloadsDuringStorm=\(reloadsDuringStorm) reloadsTotal=\(total) seconds=\(String(format: "%.2f", seconds)) rate=\(String(format: "%.1f", Double(reloadsDuringStorm) / seconds))/s")
            return (writes, reloadsDuringStorm, seconds)
        }
    }

    /// 이전 구현(50ms 선행 스로틀)은 같은 폭주에서 초당 약 13회 읽었다.
    @Test func anOpenPopoverReloadsAboutOncePerSecondDuringAHookStorm() async throws {
        let result = try await storm(popoverOpen: true)
        let rate = Double(result.reloads) / result.seconds
        #expect(result.reloads >= 1)
        #expect(rate <= 2.5, "rate \(rate)/s")
    }

    @Test func aClosedPopoverReloadsEvenLessOften() async throws {
        let open = try await storm(popoverOpen: true)
        let closed = try await storm(popoverOpen: false)
        #expect(closed.reloads >= 1)
        #expect(closed.reloads <= open.reloads, "closed \(closed.reloads) vs open \(open.reloads)")
        #expect(Double(closed.reloads) / closed.seconds <= 1.0)
    }
}
