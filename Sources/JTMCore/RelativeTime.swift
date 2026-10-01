import Foundation

public enum RelativeTime {
    /// "just now", "5m ago", "3h ago", "2d ago"
    public static func string(from date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3_600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }
}
