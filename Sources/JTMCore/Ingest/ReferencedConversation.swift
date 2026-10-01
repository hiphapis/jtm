import Foundation

/// Codex 데스크톱 앱이 ChatGPT 대화를 참조해 시작한 세션의 첫 프롬프트 머리말
/// (`docs/01-product/auto-capture.md`의 "참조한 ChatGPT 대화" 머리말):
/// ```
/// ## Referenced ChatGPT conversation:
/// <설명> {"conversationId":"…","title":"…",…}
/// ## My request:
/// Continuing from [<제목>](chatgpt-conversation://<id>): <사용자 요청>
/// ```
/// 프로세스를 띄우지 않는 순수 파서다. JSON이 깨져 있어도 요청 문장은 쓴다.
public struct ReferencedConversation: Equatable, Sendable {
    public static let headerPrefix = "## Referenced ChatGPT conversation:"
    static let requestMarker = "## My request:"

    /// 참조한 대화의 ID. JSON에 없거나 모양이 이상하면 nil(URL과 외부 키에 들어가므로 안전한 문자만 받는다).
    public var conversationId: String?
    /// 참조한 대화의 제목(JSON의 `title`).
    public var referencedTitle: String?
    /// `## My request:` 뒤의 본문에서 `Continuing from [..](chatgpt-conversation://..):`를 뗀 것. 없거나 비면 nil.
    public var request: String?

    /// 앞쪽 공백을 건너뛰고 머리말로 시작하는가.
    public static func hasHeader(_ text: String) -> Bool {
        text.drop(while: \.isWhitespace).hasPrefix(headerPrefix)
    }

    /// 머리말로 시작하는 프롬프트면 파싱한 결과, 아니면 nil. JSON 파싱 실패는 오류가 아니다(해당 필드만 nil).
    public static func parse(_ prompt: String) -> ReferencedConversation? {
        let trimmed = Substring(prompt.drop(while: \.isWhitespace))
        guard trimmed.hasPrefix(headerPrefix) else { return nil }
        let afterHeader = trimmed.dropFirst(headerPrefix.count)

        var reference = ReferencedConversation()
        var rest = afterHeader
        if let json = firstJSONObject(in: afterHeader),
           let object = (try? JSONSerialization.jsonObject(with: Data(json.text.utf8))) as? [String: Any] {
            reference.conversationId = (object["conversationId"] as? String).flatMap(safeIdentifier)
            reference.referencedTitle = object["title"] as? String
            rest = json.remainder  // JSON 안에 마커 문구가 들어 있어도 속지 않게 JSON 뒤에서 찾는다
        }
        if let marker = rest.range(of: requestMarker) {
            let request = stripContinuing(String(rest[marker.upperBound...]))
            reference.request = request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : request
        }
        return reference
    }

    /// 목록/제목에 쓸 제목: 요청 문장 → 참조한 대화 제목 → nil. 둘 다 같은 규칙(한 줄, 앞 60자)을 따른다.
    public var title: String? {
        request.flatMap(Reconciler.normalizedTitle) ?? referencedTitle.flatMap(Reconciler.normalizedTitle)
    }

    // MARK: Parsing helpers

    /// 대화 ID는 URL(`https://chatgpt.com/c/<id>`)과 외부 키에 들어간다: 영숫자, `-`, `_`만, 128자 이하.
    private static func safeIdentifier(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F })
        else { return nil }
        return value
    }

    /// 첫 `{`부터 짝이 맞는 `}`까지(문자열과 이스케이프를 고려한다). Python `raw_decode`처럼 객체 뒤의 글자는 무시한다.
    /// 짝이 안 맞으면 nil.
    private static func firstJSONObject(in text: Substring) -> (text: String, remainder: Substring)? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let end = text.index(after: index)
                    return (String(text[start..<end]), text[end...])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// 요청 앞의 `Continuing from [<제목>](chatgpt-conversation://<id>):`를 뗀다. 제목에 `]`가 있어도 `](chatgpt-conversation://`로 닫는다.
    private static func stripContinuing(_ text: String) -> String {
        let pattern = #"^\s*Continuing from \[[^\n]*?\]\(chatgpt-conversation://[^)\s]*\):\s*"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return text }
        return String(text[range.upperBound...])
    }
}
