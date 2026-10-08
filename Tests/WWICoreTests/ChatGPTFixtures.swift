import Foundation

/// Codex 데스크톱 앱의 "참조한 ChatGPT 대화" 머리말 프롬프트(실측한 모양)를 가짜 값으로 만든 것.
/// 실제 대화 제목, ID, 경로, 사용자 문장은 넣지 않는다.
enum ChatGPTFixtures {
    static let conversationId = "00000000-0000-4000-8000-0000000000c1"
    static let otherConversationId = "00000000-0000-4000-8000-0000000000c2"
    static let referencedTitle = "Example referenced title"
    /// 홈 아래 ChatGPT 프로젝트 폴더(슬러그는 지어낸 값).
    static let projectCwd = "/Users/me/.codex/.chatgpt-projects/g-p-00000000000040008000000000000001-example"

    /// JSON에는 중괄호가 든 문자열, 이스케이프된 따옴표, 중첩 객체가 있다(깊이 세기만으로는 틀리는 모양).
    static func json(id: String? = conversationId, title: String? = referencedTitle) -> String {
        var fields: [String] = []
        if let id { fields.append(#""conversationId":"\#(id)""#) }
        if let title { fields.append(#""title":"\#(title)""#) }
        fields.append(#""priorConversation":{"summary":"has {braces} and \"quotes\" and ## My request: inside","turns":[{"role":"user"}]}"#)
        return "{" + fields.joined(separator: ",") + "}"
    }

    static let headerIntro = "## Referenced ChatGPT conversation:\nThe user referenced a prior ChatGPT conversation. Use it as context."

    /// 머리말 + `## My request:` (앞에 `Continuing from [..](..):`가 붙는다).
    static func withRequest(
        request: String = "Write the release notes\nfor version two", id: String = conversationId,
        title: String = referencedTitle, json: String? = nil
    ) -> String {
        """
        \(headerIntro) \(json ?? self.json(id: id, title: title))
        ## My request:
        Continuing from [\(title)](chatgpt-conversation://\(id)): \(request)
        """
    }

    /// 머리말만 있고 `## My request:`가 없다.
    static func withoutRequest(id: String? = conversationId, title: String? = referencedTitle) -> String {
        "\(headerIntro) \(json(id: id, title: title))\n"
    }

    /// JSON이 깨졌지만(닫는 중괄호 없음) 요청 문장은 있다.
    static let malformedJSON = """
        \(headerIntro) {"conversationId":"\(conversationId)","title":"\(referencedTitle)","priorConversation":{"summary":"cut off
        ## My request:
        Continuing from [\(referencedTitle)](chatgpt-conversation://\(conversationId)): Summarize the open questions
        """
}
