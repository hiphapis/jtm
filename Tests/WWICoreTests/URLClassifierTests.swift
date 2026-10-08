import Testing
@testable import WWICore

@Suite struct URLClassifierTests {
    @Test func chatgptChat() {
        let url = "https://chatgpt.com/c/d79e1949-d0d9-4dee-8ec0-79e0d341b41c"
        #expect(URLClassifier.classify(url) == .chatgptChat(.init(chatId: "d79e1949-d0d9-4dee-8ec0-79e0d341b41c", url: url)))
    }

    @Test func chatgptProjectChat() {
        let url = "https://chatgpt.com/g/g-p-05cf98908aa74814b7b82b700520204d-sample-project/c/d79e1949-d0d9-4dee-8ec0-79e0d341b41c"
        #expect(URLClassifier.classify(url) == .chatgptChat(.init(chatId: "d79e1949-d0d9-4dee-8ec0-79e0d341b41c", url: url)))
    }

    @Test func claudeChat() {
        let url = "https://claude.ai/chat/0b7f3c52-1d4e-4a8b-9c6d-2f1e5a7b8c90"
        #expect(URLClassifier.classify(url) == .claudeChat(.init(chatUuid: "0b7f3c52-1d4e-4a8b-9c6d-2f1e5a7b8c90", url: url)))
    }

    @Test func ignoresQueryAndTrimsWhitespace() {
        let url = "https://chatgpt.com/c/abc-123?model=gpt-5"
        #expect(URLClassifier.classify("  \(url)\n") == .chatgptChat(.init(chatId: "abc-123", url: url)))
    }

    @Test(arguments: [
        "https://example.com/docs",
        "https://claude.ai/chat/new",
        "https://chatgpt.com/",
        "https://chatgpt.com/g/g-p-1-x",
        "not a url",
    ])
    func everythingElseIsPlainURL(_ raw: String) {
        #expect(URLClassifier.classify(raw) == .url(.init(url: raw)))
    }
}
