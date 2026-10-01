import Foundation

/// 붙여넣은 URL을 Location payload로 분류한다(https만 채팅으로 인식). → docs/01-product/resolver.md
public enum URLClassifier {
    private static let chatgptHosts: Set<String> = ["chatgpt.com", "www.chatgpt.com", "chat.openai.com"]

    public static func classify(_ raw: String) -> Locator {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return .url(.init(url: text))
        }
        let path = url.pathComponents.filter { $0 != "/" }

        if chatgptHosts.contains(host) {
            switch path.count {
            case 2 where path[0] == "c": return .chatgptChat(.init(chatId: path[1], url: text))
            case 4 where path[0] == "g" && path[2] == "c": return .chatgptChat(.init(chatId: path[3], url: text))
            default: break
            }
        }
        if host == "claude.ai", path.count == 2, path[0] == "chat", UUID(uuidString: path[1]) != nil {
            return .claudeChat(.init(chatUuid: path[1], url: text))
        }
        return .url(.init(url: text))
    }
}
