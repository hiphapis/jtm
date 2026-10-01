import Foundation
import Testing
@testable import JTMAppCore
@testable import JTMCore

/// 변경 알림을 시각과 함께 모은다.
private final class Notifications: @unchecked Sendable {
    private let lock = NSLock()
    private var instants: [ContinuousClock.Instant] = []
    var count: Int { lock.withLock { instants.count } }
    func record() { lock.withLock { instants.append(.now) } }

    /// `since` 이후 첫 알림이 올 때까지 기다린다. 시간 안에 안 오면 nil.
    func wait(after since: ContinuousClock.Instant, timeout: Duration = .seconds(5)) async -> ContinuousClock.Instant? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let hit = lock.withLock({ instants.first { $0 >= since } }) { return hit }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

private func summary(_ name: String, _ samples: [Double]) -> String {
    let sorted = samples.sorted()
    let median = sorted[sorted.count / 2]
    return "\(name): n=\(samples.count) min=\(String(format: "%.1f", sorted.first!))ms median=\(String(format: "%.1f", median))ms max=\(String(format: "%.1f", sorted.last!))ms"
}

/// 인수 기준("목록 갱신 < 1초")의 논리 보장: 알림 시각은 순수 함수로 정해지고, 벽시계는 쓰지 않는다.
@Suite struct DebounceDeadlineTests {
    private typealias Plan = (deadline: TimeInterval, firstPending: TimeInterval)
    private func plan(now: TimeInterval, first: TimeInterval?, debounce: TimeInterval = 0.25, maxWait: TimeInterval = 1) -> Plan {
        DatabaseWatcher.debounceDeadline(now: now, firstPending: first, debounce: debounce, maxWait: maxWait)
    }

    @Test func aSingleEventFiresOneDebounceLaterAndStartsTheBatch() {
        let result = plan(now: 10, first: nil)
        #expect(result.deadline == 10.25 && result.firstPending == 10)
    }

    @Test func eventsKeepPushingTheDeadlineButNeverPastMaxWaitFromTheFirstOne() {
        var first: TimeInterval?
        var last: Plan = (0, 0)
        for step in 0..<20 {  // 0.1초 간격 이벤트: 디바운스(0.25)보다 촘촘해서 계속 밀린다
            last = plan(now: 10 + Double(step) * 0.1, first: first)
            first = last.firstPending
            #expect(last.deadline <= 11, "step \(step)")  // 첫 이벤트(10) + maxWait(1)
        }
        #expect(last.firstPending == 10 && last.deadline == 11)
    }

    @Test func aQuietBatchFiresAtLastEventPlusDebounce() {
        let first = plan(now: 5, first: nil)
        let second = plan(now: 5.1, first: first.firstPending)
        #expect(second.deadline == 5.1 + 0.25 && second.firstPending == 5)
    }

    @Test func theClosedPopoverUsesTheSlowerValuesButStillFiresWithinOneSecondOfAQuietChange() {
        let options = DatabaseWatcher.Options()
        let single = plan(now: 0, first: nil, debounce: options.idleDebounce, maxWait: options.idleMaxWait)
        #expect(single.deadline == options.idleDebounce && single.deadline < 1)
        let storm = plan(now: 1.9, first: 0, debounce: options.idleDebounce, maxWait: options.idleMaxWait)
        #expect(storm.deadline == options.idleMaxWait)
    }

    @Test func negativeValuesAreClamped() {
        let result = plan(now: 3, first: nil, debounce: -1, maxWait: -1)
        #expect(result.deadline == 3)
    }

    /// 기본값의 논리 보장: 파일 이벤트 경로는 디바운스(0.25초)로 1초 안에 나가고, 이벤트를 놓쳤을 때 폴링 경로의 최악은
    /// `pollInterval`(+25% leeway) + 디바운스다.
    @Test func theDefaultsKeepTheFileEventPathUnderASecondAndBoundThePollingPath() {
        let options = DatabaseWatcher.Options()
        #expect(options.debounce < 1 && options.maxWait <= 1)
        #expect(options.pollInterval * 1.25 + options.debounce < 3.5)  // leeway 25% 포함
    }
}

@Suite(.serialized) struct DatabaseWatcherTests {
    /// 실제 파일시스템 스모크: 쓰기가 커밋된 순간부터 콜백까지 걸린 시간을 여러 번 잰다.
    /// 파일 이벤트를 놓치면 2초 폴링이 받으므로 벽시계 상한은 `pollInterval(+25% leeway) + debounce + 여유` ≈ 3.5초다.
    /// 1초 인수 기준의 논리 보장은 `DebounceDeadlineTests`가 맡고, 여기서는 알림이 빠지지 않는 것과 지연 분포를 `LATENCY`로 보고만 한다.
    /// - persistent: 앱과 같은 프로세스의 쓰기 연결 하나로 계속 쓴다.
    /// - hookLike: 훅처럼 매번 새 `Store`를 열고 쓰고 닫는다(마지막 연결이 닫히면 -wal이 지워졌다 다시 생긴다).
    @Test(arguments: ["persistent", "hookLike"]) func changeNotificationsArriveWithinThePollingBound(mode: String) async throws {
        try await withTempDB { path in
            let seed = try Store(path: path)
            let ticket = try seed.createTicket(title: "t", status: .active)
            let hits = Notifications()
            let watcher = DatabaseWatcher(path: path) { hits.record() }
            watcher.start()
            defer { watcher.stop() }
            try await Task.sleep(for: .milliseconds(300))  // 감시가 걸릴 시간

            var samples: [Double] = []
            let statuses: [TicketStatus] = [.waiting, .active]
            for index in 0..<20 {
                let status = statuses[index % 2]
                let before = ContinuousClock.now
                if mode == "hookLike" {
                    let store = try Store(path: path)
                    try store.patchTicket(id: ticket.id, TicketPatch(status: status))
                } else {
                    try seed.patchTicket(id: ticket.id, TicketPatch(status: status))
                }
                let committed = ContinuousClock.now
                let hit = try #require(await hits.wait(after: before), "no notification for write \(index)")
                samples.append(milliseconds(max(hit - committed, .zero)))
                try await Task.sleep(for: .milliseconds(150))
            }
            print("LATENCY \(summary(mode, samples))")
            let options = DatabaseWatcher.Options()
            let bound = (options.pollInterval * 1.25 + options.debounce + 1.25) * 1_000  // ≈ 4.0초: 한 번의 폴링 주기를 넘기지 않는다
            #expect(samples.max()! < bound, "max \(samples.max()!) ms")
        }
    }

    @Test func pollingAloneCatchesChangesWhenFileEventsAreMissed() async throws {
        try await withTempDB { path in
            let writer = try Store(path: path)
            let ticket = try writer.createTicket(title: "t", status: .active)
            let hits = Notifications()
            var options = DatabaseWatcher.Options()
            options.useFileEvents = false
            options.pollInterval = 0.2
            let watcher = DatabaseWatcher(path: path, options: options) { hits.record() }
            watcher.start()
            defer { watcher.stop() }
            try await Task.sleep(for: .milliseconds(400))
            let before = ContinuousClock.now
            try writer.patchTicket(id: ticket.id, TicketPatch(status: .waiting))
            let hit = try #require(await hits.wait(after: before, timeout: .seconds(3)))
            #expect(hit - before < .seconds(1))
        }
    }

    @Test func aDatabaseCreatedAfterTheWatcherStartedIsNoticed() async throws {
        try await withTempDB { path in
            let hits = Notifications()
            var options = DatabaseWatcher.Options()
            options.pollInterval = 0.2
            let watcher = DatabaseWatcher(path: path, options: options) { hits.record() }
            watcher.start()
            defer { watcher.stop() }
            try await Task.sleep(for: .milliseconds(300))
            let before = ContinuousClock.now
            let store = try Store(path: path)  // 폴더와 파일이 이제 생긴다
            _ = try store.createTicket(title: "first")
            #expect(await hits.wait(after: before, timeout: .seconds(3)) != nil)
            let second = ContinuousClock.now
            _ = try store.createTicket(title: "second")
            #expect(await hits.wait(after: second, timeout: .seconds(3)) != nil)
        }
    }

    @Test func manyCommitsInARowAreCoalescedIntoFewNotifications() async throws {
        try await withTempDB { path in
            let store = try Store(path: path)
            let hits = Notifications()
            let watcher = DatabaseWatcher(path: path) { hits.record() }
            watcher.start()
            defer { watcher.stop() }
            try await Task.sleep(for: .milliseconds(300))
            for index in 0..<50 { _ = try store.createTicket(title: "t\(index)") }
            try await Task.sleep(for: .milliseconds(600))
            #expect(hits.count >= 1 && hits.count < 25, "got \(hits.count)")
        }
    }

    @Test func stopSilencesTheWatcher() async throws {
        try await withTempDB { path in
            let store = try Store(path: path)
            let hits = Notifications()
            let watcher = DatabaseWatcher(path: path) { hits.record() }
            watcher.start()
            try await Task.sleep(for: .milliseconds(300))
            watcher.stop()
            try await Task.sleep(for: .milliseconds(100))
            _ = try store.createTicket(title: "after stop")
            try await Task.sleep(for: .milliseconds(500))
            #expect(hits.count == 0)
        }
    }
}
