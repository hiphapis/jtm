import Foundation
import Testing
@testable import JTMCore

@Suite struct LocatorTests {
    @Test func orcaTerminalEncodesFlatPayloadWithoutNils() throws {
        let locator = Locator.orcaTerminal(.init(terminalHandle: "term_x", tabId: "tab-1"))
        let json = String(decoding: try locator.jsonData(), as: UTF8.self)
        #expect(json == #"{"tabId":"tab-1","terminalHandle":"term_x"}"#)
    }

    @Test(arguments: [
        Locator.orcaTerminal(.init(terminalHandle: "term_x", worktreeId: "w", tabId: "t", ptyId: "p", titleHint: "h")),
        .codexThread(.init(threadId: "th-1")),
        .claudeChat(.init(chatUuid: "u", url: "https://claude.ai/chat/u")),
        .claudeCode(.init(sessionId: "s", cwd: "/tmp")),
        .chatgptChat(.init(chatId: "c", url: "https://chatgpt.com/c/c")),
        .url(.init(url: "https://example.com")),
    ])
    func roundTripsThroughKind(_ locator: Locator) throws {
        let decoded = try Locator(kind: locator.kind, json: try locator.jsonData())
        #expect(decoded == locator)
    }
}
