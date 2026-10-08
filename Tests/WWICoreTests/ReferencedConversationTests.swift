import Foundation
import Testing
@testable import WWICore

// "참조한 ChatGPT 대화" 머리말 파서와 제목 규칙. 프롬프트는 ChatGPTFixtures의 가짜 값이다.

@Suite struct ReferencedConversationTests {
    @Test func parsesIdTitleAndRequestWithoutTheContinuingPrefix() throws {
        let parsed = try #require(ReferencedConversation.parse(ChatGPTFixtures.withRequest()))
        #expect(parsed.conversationId == ChatGPTFixtures.conversationId)
        #expect(parsed.referencedTitle == ChatGPTFixtures.referencedTitle)
        #expect(parsed.request == "Write the release notes\nfor version two")
        #expect(parsed.title == "Write the release notes for version two")
    }

    @Test func leadingWhitespaceBeforeTheHeaderIsTolerated() throws {
        let parsed = try #require(ReferencedConversation.parse("\n  \t" + ChatGPTFixtures.withRequest()))
        #expect(parsed.title == "Write the release notes for version two")
        #expect(ReferencedConversation.hasHeader("  \n## Referenced ChatGPT conversation: x"))
    }

    @Test func titleIsSingleLinedAndCutAtSixtyCharacters() throws {
        let long = String(repeating: "word ", count: 30)
        let parsed = try #require(ReferencedConversation.parse(ChatGPTFixtures.withRequest(request: long)))
        #expect(parsed.title == String(String(repeating: "word ", count: 12).dropLast()))
        #expect(parsed.title?.count == 59)
    }

    @Test func aBracketInTheReferencedTitleDoesNotBreakTheStrip() throws {
        let tricky = "Plan [draft] v2"
        let parsed = try #require(ReferencedConversation.parse(ChatGPTFixtures.withRequest(request: "Do it", title: tricky)))
        #expect(parsed.request == "Do it" && parsed.referencedTitle == tricky)
    }

    @Test func missingRequestFallsBackToTheReferencedTitle() throws {
        let parsed = try #require(ReferencedConversation.parse(ChatGPTFixtures.withoutRequest()))
        #expect(parsed.request == nil)
        #expect(parsed.conversationId == ChatGPTFixtures.conversationId)
        #expect(parsed.title == ChatGPTFixtures.referencedTitle)
    }

    @Test func anEmptyRequestAfterThePrefixCountsAsMissing() throws {
        let prompt = ChatGPTFixtures.withRequest(request: "   ")
        #expect(ReferencedConversation.parse(prompt)?.title == ChatGPTFixtures.referencedTitle)
    }

    @Test func missingRequestAndTitleGiveNoTitleButKeepTheId() throws {
        let parsed = try #require(ReferencedConversation.parse(ChatGPTFixtures.withoutRequest(title: nil)))
        #expect(parsed.title == nil && parsed.conversationId == ChatGPTFixtures.conversationId)
    }

    @Test func malformedJSONStillYieldsTheRequestButNoId() throws {
        let parsed = try #require(ReferencedConversation.parse(ChatGPTFixtures.malformedJSON))
        #expect(parsed.conversationId == nil && parsed.referencedTitle == nil)
        #expect(parsed.title == "Summarize the open questions")
    }

    @Test func noJSONAtAllIsTolerated() throws {
        let parsed = try #require(ReferencedConversation.parse("## Referenced ChatGPT conversation: nothing\n## My request:\nHello there"))
        #expect(parsed.title == "Hello there" && parsed.conversationId == nil)
    }

    @Test func markerTextInsideTheJSONIsNotTakenForTheRequest() throws {
        // 픽스처 JSON의 문자열 안에 `## My request:`가 들어 있다.
        let parsed = try #require(ReferencedConversation.parse(ChatGPTFixtures.withRequest(request: "Real request")))
        #expect(parsed.title == "Real request")
    }

    @Test func unsafeConversationIdsAreDropped() throws {
        for bad in ["../../x", "a b", "a/b", "", String(repeating: "a", count: 129), "id?x=1"] {
            let prompt = ChatGPTFixtures.withoutRequest(id: bad)
            #expect(ReferencedConversation.parse(prompt)?.conversationId == nil, "\(bad)")
        }
    }

    @Test func nonHeaderPromptsAreNotParsed() {
        #expect(ReferencedConversation.parse("Fix the flaky test") == nil)
        #expect(ReferencedConversation.parse("Please see ## Referenced ChatGPT conversation: inside") == nil)
        #expect(ReferencedConversation.parse("") == nil)
        #expect(!ReferencedConversation.hasHeader("My request: ## Referenced ChatGPT conversation:"))
    }

    // MARK: Reconciler.title(fromPrompt:)

    @Test func titleFromPromptFollowsTheHeaderRulesAndLeavesOtherPromptsAlone() {
        #expect(Reconciler.title(fromPrompt: ChatGPTFixtures.withRequest()) == "Write the release notes for version two")
        #expect(Reconciler.title(fromPrompt: ChatGPTFixtures.withoutRequest()) == ChatGPTFixtures.referencedTitle)
        #expect(Reconciler.title(fromPrompt: ChatGPTFixtures.withoutRequest(title: nil)) == nil)
        #expect(Reconciler.title(fromPrompt: ChatGPTFixtures.malformedJSON) == "Summarize the open questions")
        #expect(Reconciler.title(fromPrompt: "  Fix the\nflaky test ") == "Fix the flaky test")
    }

    @Test func theHeaderBlockIsNeverUsedAsATitle() {
        let prompts = [
            ChatGPTFixtures.withRequest(), ChatGPTFixtures.withoutRequest(), ChatGPTFixtures.withoutRequest(title: nil),
            ChatGPTFixtures.malformedJSON, "## Referenced ChatGPT conversation:", "## Referenced ChatGPT conversation: {not json",
        ]
        for prompt in prompts {
            #expect(Reconciler.title(fromPrompt: prompt)?.contains("Referenced ChatGPT") != true, "\(prompt)")
        }
    }
}
