import Foundation

/// Codex가 남기는 세션 기록(`<CODEX_HOME>/sessions/**/rollout-*-<threadId>.jsonl`)에서 첫 프롬프트를 읽는다. 읽기 전용이다.
/// 첫 `role: user` 메시지는 환경 안내 같은 합성 메시지일 수 있어서, 머리말로 시작하는 사용자 메시지를 찾는다.
public final class CodexRollout {
    /// 기록 파일에서 읽는 최대 크기와 줄 수. 첫 프롬프트는 앞쪽에 있다(`session_meta` 줄이 크다).
    static let readLimit = 8 * 1_048_576
    static let lineLimit = 400

    private let sessionsDirectory: String
    private var index: [String]?  // 첫 조회 때 한 번만 만든다. 한 스레드에서만 쓴다.

    /// `codexHome`은 `CODEX_HOME` 또는 `~/.codex`.
    public init(codexHome: String) {
        sessionsDirectory = (codexHome as NSString).appendingPathComponent("sessions")
    }

    public static func defaultHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let home = environment["CODEX_HOME"], !home.isEmpty { return home }
        return NSHomeDirectory() + "/.codex"
    }

    /// 스레드의 기록 파일 경로. 스레드 ID로 경로를 만들지 않고 `rollout-*-<id>.jsonl` 이름과 비교만 한다.
    public func file(forThread threadId: String) -> String? {
        guard !threadId.isEmpty else { return nil }
        if index == nil {
            var found: [String] = []
            if let walker = FileManager.default.enumerator(atPath: sessionsDirectory) {
                for case let relative as String in walker where relative.hasSuffix(".jsonl") {
                    if (relative as NSString).lastPathComponent.hasPrefix("rollout-") { found.append(relative) }
                }
            }
            index = found.sorted()
        }
        let suffix = "-\(threadId).jsonl"
        return index?.first { $0.hasSuffix(suffix) }.map { (sessionsDirectory as NSString).appendingPathComponent($0) }
    }

    /// 파일 앞부분에서 "참조한 ChatGPT 대화" 머리말로 시작하는 사용자 메시지를 찾아 파싱한다. 없으면 nil.
    public static func referencedConversation(inFile path: String) -> ReferencedConversation? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let needle = Data(ReferencedConversation.headerPrefix.utf8)
        var pending = Data()
        var consumed = 0
        var lines = 0
        while consumed < readLimit, lines < lineLimit {
            guard let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            consumed += chunk.count
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = Data(pending[pending.index(after: newline)...])
                lines += 1
                if line.range(of: needle) != nil, let found = referencedConversation(inLine: Data(line)) { return found }
                if lines >= lineLimit { return nil }
            }
        }
        return pending.range(of: needle) != nil ? referencedConversation(inLine: pending) : nil
    }

    /// 기록 한 줄이 사용자 메시지(`response_item`의 `message`/`user`, 또는 `event_msg`의 `user_message`)이고 머리말로 시작하면 파싱한다.
    static func referencedConversation(inLine line: Data) -> ReferencedConversation? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return nil }
        var texts: [String] = []
        switch object["type"] as? String {
        case "response_item":
            guard payload["type"] as? String == "message", payload["role"] as? String == "user" else { return nil }
            if let parts = payload["content"] as? [[String: Any]] { texts = parts.compactMap { $0["text"] as? String } }
        case "event_msg":
            guard payload["type"] as? String == "user_message", let message = payload["message"] as? String else { return nil }
            texts = [message]
        default:
            return nil
        }
        return texts.lazy.compactMap { ReferencedConversation.parse($0) }.first
    }
}
