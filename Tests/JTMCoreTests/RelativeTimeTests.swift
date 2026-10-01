import Foundation
import Testing
@testable import JTMCore

@Suite struct RelativeTimeTests {
    @Test func formatsElapsedTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(elapsed: TimeInterval, expected: String)] = [
            (0, "just now"), (59, "just now"), (60, "1m ago"), (3_599, "59m ago"),
            (3_600, "1h ago"), (86_399, "23h ago"), (86_400, "1d ago"), (864_000, "10d ago"),
            (-30, "just now"),
        ]
        for (elapsed, expected) in cases {
            #expect(RelativeTime.string(from: now.addingTimeInterval(-elapsed), now: now) == expected)
        }
    }
}
