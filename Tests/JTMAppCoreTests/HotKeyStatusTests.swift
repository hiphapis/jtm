import Testing
@testable import JTMAppCore

@Suite(.korean) struct HotKeyStatusTests {
    @Test func aRegisteredShortcutShowsItsLabelAndNoProblem() {
        let status = HotKeyStatus.registered(label: "⌥⌘J")
        #expect(status.label == "⌥⌘J" && status.problem == nil)
    }

    @Test func anExclusiveConflictSaysAnotherAppHasIt() {
        let status = HotKeyStatus.failed(label: "⌥⌘J", code: HotKeyStatus.existsError)
        #expect(HotKeyStatus.existsError == -9878)
        #expect(status.problem == "⌥⌘J 단축키를 다른 앱이 이미 쓰고 있어요")
    }

    @Test func anyOtherFailureShowsTheCode() {
        #expect(HotKeyStatus.failed(label: "⌥⌘J", code: -50).problem == "⌥⌘J 단축키를 등록하지 못했어요 (코드 -50)")
    }
}
