import Foundation
import Testing
@testable import JTMCore

private final class SleepLog {
    var delays: [TimeInterval] = []
    var total: TimeInterval { delays.reduce(0, +) }
}

private let claude = Locator.ClaudeCode(sessionId: "sess-1", cwd: "/Users/me/work dir")

// MARK: S5 — 하나의 "주 위치" 정의

@Suite struct PrimaryLocationTests {
    @Test func sequencePrimaryIsResolverChoose() {
        let scenarios: [[Location]] = [
            [],
            [location(1, .url(.init(url: "u")), seen: 100), location(2, .codexThread(.init(threadId: "t")), seen: 900)],
            [location(1, .orcaTerminal(.init(terminalHandle: "a")), seen: 100),
             location(2, .orcaTerminal(.init(terminalHandle: "b")), seen: 900),
             location(3, .url(.init(url: "u")), seen: 9_999)],
            [location(4, .url(.init(url: "a")), seen: 5), location(3, .url(.init(url: "b")), seen: 5)],
        ]
        for locations in scenarios {
            #expect(locations.primary == Resolver.choose(from: locations))
        }
    }

    @Test func newerNonOrcaLocationWinsOverOlderOne() {
        let old = location(1, .url(.init(url: "u")), seen: 100)
        let recent = location(2, .codexThread(.init(threadId: "t")), seen: 900)
        #expect([old, recent].primary?.id == 2)
    }
}

// MARK: S7 — 콜드 스타트 재시도

@Suite struct ColdStartTests {
    let stored = Locator.OrcaTerminal(terminalHandle: "term_1", worktreeId: "wt", tabId: "tab", ptyId: "pty")

    @Test func retriesSwitchWithBackoffWhileOrcaIsNotReady() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_1"), orcaNotReady, orcaNotReady, switchOK(tabId: "tab", worktreeId: "wt"))
        let sleeps = SleepLog()
        let loc = location(1, .orcaTerminal(stored))
        let result = makeResolver(runner, sleep: { sleeps.delays.append($0) }).resolve(loc, among: [loc])
        #expect(result.ok)
        #expect(runner.argvs == [openOrca, switchArgv("term_1"), switchArgv("term_1"), switchArgv("term_1")])
        #expect(sleeps.delays == [0.25, 0.5])
    }

    @Test func givesUpAfterAboutFiveSecondsWithoutTryingRecovery() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_1"), orcaNotReady)
        let sleeps = SleepLog()
        let loc = location(1, .orcaTerminal(stored))
        let result = makeResolver(runner, sleep: { sleeps.delays.append($0) }).resolve(loc, among: [loc])
        #expect(!result.ok)
        #expect(result.message.contains("Orca is not running"))
        #expect(sleeps.total == 5)
        #expect(runner.argvs.filter { $0 == listArgv }.isEmpty)
        #expect(runner.argvs.filter { $0 == switchArgv("term_1") }.count == 6)
    }

    @Test func staleHandleIsNotRetried() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_1"), switchStale)
        runner.on(listArgv, listOK([]))
        let sleeps = SleepLog()
        let loc = location(1, .orcaTerminal(stored))
        _ = makeResolver(runner, sleep: { sleeps.delays.append($0) }).resolve(loc, among: [loc])
        #expect(sleeps.delays.isEmpty)
        #expect(runner.argvs == [openOrca, switchArgv("term_1"), listArgv])
    }

    @Test func timedOutSwitchIsNotRetried() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_1"), CommandResult(exitCode: 124, stderr: "timed out after 8s"))
        let sleeps = SleepLog()
        let loc = location(1, .orcaTerminal(stored))
        let result = makeResolver(runner, sleep: { sleeps.delays.append($0) }).resolve(loc, among: [loc])
        #expect(!result.ok && sleeps.delays.isEmpty)
        #expect(result.message.contains("timed out"))
    }

    @Test func notFoundErrorCodeCountsAsStale() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_1"), CommandResult(exitCode: 1, stdout: #"{"ok":false,"error":{"code":"terminal_not_found"}}"#))
        runner.on(listArgv, listOK([]))
        let sleeps = SleepLog()
        let loc = location(1, .orcaTerminal(stored))
        _ = makeResolver(runner, sleep: { sleeps.delays.append($0) }).resolve(loc, among: [loc])
        #expect(sleeps.delays.isEmpty)
        #expect(runner.argvs.contains(listArgv))
    }
}

// MARK: S8 — 클립보드 폴백

@Suite struct ResumeFallbackTests {
    let terminal = Locator.OrcaTerminal(terminalHandle: "term_old", tabId: "tab", ptyId: "pty")

    @Test func claudeCodeFallsBackToClipboardWhenDelegatedMoveFails() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_1"), orcaNotReady)
        let code = location(1, .claudeCode(claude))
        let term = location(2, .orcaTerminal(.init(terminalHandle: "term_1")))
        let result = makeResolver(runner).resolve(code, among: [code, term])
        #expect(result.ok)
        #expect(result.location.id == 1)
        #expect(result.message.contains("copied resume command"))
        #expect(runner.calls.last == .init(
            argv: ["pbcopy"], stdin: #"cd '/Users/me/work dir' && claude --resume 'sess-1'"#, timeout: 3))
    }

    @Test func orcaTerminalFallsBackToClaudeResumeWhenRecoveryFails() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), switchStale)
        runner.on(listArgv, listOK([("other", "p", "t")]))
        let term = location(1, .orcaTerminal(terminal))
        let code = location(2, .claudeCode(claude))
        let result = makeResolver(runner).resolve(term, among: [term, code])
        #expect(result.ok)
        #expect(result.location.id == 2)
        #expect(result.message.contains("copied resume command"))
        #expect(runner.calls.last?.stdin == #"cd '/Users/me/work dir' && claude --resume 'sess-1'"#)
        #expect(!runner.argvs.contains { $0.count > 1 && $0[1] == "search" })
    }

    @Test func orcaTerminalFallsBackToCodexResume() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), switchStale)
        runner.on(listArgv, listOK([]))
        let term = location(1, .orcaTerminal(terminal))
        let codex = location(2, .codexThread(.init(threadId: "019a-thread")))
        let result = makeResolver(runner).resolve(term, among: [term, codex])
        #expect(result.ok && result.location.id == 2)
        #expect(runner.calls.last?.stdin == "codex resume '019a-thread'")
    }

    @Test func codexResumeFallbackChangesDirectoryFirstWhenCwdIsKnown() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), switchStale)
        runner.on(listArgv, listOK([]))
        let term = location(1, .orcaTerminal(terminal))
        let codex = location(2, .codexThread(.init(threadId: "019a-thread", cwd: "/Users/me/it's here")))
        let result = makeResolver(runner).resolve(term, among: [term, codex])
        #expect(result.ok && result.location.id == 2)
        #expect(runner.calls.last?.stdin == #"cd '/Users/me/it'\''s here' && codex resume '019a-thread'"#)
    }

    @Test func claudeIsPreferredOverCodexAndNewestClaudeWins() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), switchStale)
        runner.on(listArgv, listOK([]))
        let term = location(1, .orcaTerminal(terminal))
        let codex = location(2, .codexThread(.init(threadId: "t")), seen: 9_000)
        let oldClaude = location(3, .claudeCode(.init(sessionId: "old", cwd: "/a")), seen: 100)
        let newClaude = location(4, .claudeCode(.init(sessionId: "new", cwd: "/b")), seen: 500)
        _ = makeResolver(runner).resolve(term, among: [term, codex, oldClaude, newClaude])
        #expect(runner.calls.last?.stdin == "cd '/b' && claude --resume 'new'")
    }

    @Test func requestedClaudeLocationIsTheFallbackEvenIfAnotherIsNewer() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_1"), orcaNotReady)
        let requested = location(1, .claudeCode(.init(sessionId: "wanted", cwd: "/w")), seen: 100)
        let newer = location(2, .claudeCode(.init(sessionId: "newer", cwd: "/n")), seen: 900)
        let term = location(3, .orcaTerminal(.init(terminalHandle: "term_1")), seen: 50)
        _ = makeResolver(runner).resolve(requested, among: [requested, newer, term])
        #expect(runner.calls.last?.stdin == "cd '/w' && claude --resume 'wanted'")
    }

    @Test func failsWithHintWhenNoResumeInfoExists() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), switchStale)
        runner.on(listArgv, listOK([]))
        let term = location(1, .orcaTerminal(terminal))
        let result = makeResolver(runner).resolve(term, among: [term])
        #expect(!result.ok && result.message.contains("orca search"))
        #expect(!runner.argvs.contains(["pbcopy"]))
    }

    @Test func nonRecoveryFailureOfDirectTerminalDoesNotCopyAnything() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), orcaNotReady)
        let term = location(1, .orcaTerminal(terminal))
        let code = location(2, .claudeCode(claude))
        let result = makeResolver(runner).resolve(term, among: [term, code])
        #expect(!result.ok)
        #expect(!runner.argvs.contains(["pbcopy"]))
    }

    @Test func reportsClipboardFailureAlongsideOriginalError() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), switchStale)
        runner.on(listArgv, listOK([]))
        runner.on(["pbcopy"], CommandResult(exitCode: 1, stderr: "denied"))
        let term = location(1, .orcaTerminal(terminal))
        let code = location(2, .claudeCode(claude))
        let result = makeResolver(runner).resolve(term, among: [term, code])
        #expect(!result.ok)
        #expect(result.message.contains("stale") && result.message.contains("denied"))
    }

    @Test func dryRunListsTheClipboardFallbackStep() throws {
        let term = location(1, .orcaTerminal(terminal))
        let code = location(2, .claudeCode(claude))
        let plan = try makeResolver(FakeRunner()).plan(code, among: [term, code])
        #expect(plan.map(\.argv).last == ["pbcopy"])
        #expect(plan.last?.stdin == #"cd '/Users/me/work dir' && claude --resume 'sess-1'"#)
    }

    @Test func goDoesNotPersistAnythingWhenOnlyTheFallbackWorked() throws {
        try withStore { store, clock, _ in
            let ticket = try store.createTicket(title: "t")
            let term = try store.addLocation(
                ticketId: ticket.id, locator: .orcaTerminal(terminal), source: .manual)
            try store.addLocation(ticketId: ticket.id, locator: .claudeCode(claude), source: .hook)
            let runner = FakeRunner()
            runner.on(switchArgv("term_old"), switchStale)
            runner.on(listArgv, listOK([]))
            clock.advance(60)
            let result = try makeResolver(runner).go(ticketId: ticket.id, store: store)
            #expect(result.ok)
            let stored = try store.locations(ticketId: ticket.id).first { $0.id == term.id }
            #expect(stored?.locator == .orcaTerminal(terminal))
        }
    }
}

// MARK: N8 — 명령 하드닝

@Suite struct OpenHardeningTests {
    @Test(arguments: ["file:///Applications/Calculator.app", "-a Calculator", "--help", "not a url", "javascript:alert(1)", ""])
    func refusesDangerousTargets(_ target: String) {
        let runner = FakeRunner()
        let loc = location(1, .url(.init(url: target)))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(!result.ok)
        #expect(result.message.contains("refusing"))
        #expect(runner.calls.isEmpty)
        #expect(throws: ResolveError.self) { try makeResolver(runner).plan(loc, among: [loc]) }
    }

    @Test(arguments: ["http://example.com", "https://example.com/a?b=c", "HTTPS://EXAMPLE.COM", "codex://threads/x", "claude://claude.ai/new"])
    func allowsWhitelistedSchemes(_ target: String) {
        let runner = FakeRunner()
        let loc = location(1, .url(.init(url: target)))
        #expect(makeResolver(runner).resolve(loc, among: [loc]).ok)
        #expect(runner.argvs == [["open", target]])
    }

    @Test func chatgptFallbackURLIsAlsoChecked() {
        let runner = FakeRunner()
        runner.on(["open", "codex://threads/abc"], CommandResult(exitCode: 1))
        let loc = location(1, .chatgptChat(.init(chatId: "abc", url: "file:///etc/passwd")))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(!result.ok)
        #expect(runner.argvs == [["open", "codex://threads/abc"]])
    }

    @Test func resumeCommandQuotesEveryValue() {
        let hostile = Locator.ClaudeCode(sessionId: "x'; rm -rf ~; echo '", cwd: "/tmp/a b'c")
        #expect(Resolver.claudeResumeCommand(hostile)
            == #"cd '/tmp/a b'\''c' && claude --resume 'x'\''; rm -rf ~; echo '\'''"#)
    }
}

@Suite struct URLClassifierHardeningTests {
    @Test func acceptsAlternateChatgptHosts() {
        for host in ["chatgpt.com", "www.chatgpt.com", "chat.openai.com"] {
            let url = "https://\(host)/c/abc-1"
            #expect(URLClassifier.classify(url) == .chatgptChat(.init(chatId: "abc-1", url: url)))
        }
    }

    @Test func onlyHTTPSCountsAsChat() {
        #expect(URLClassifier.classify("http://chatgpt.com/c/abc") == .url(.init(url: "http://chatgpt.com/c/abc")))
        let claude = "http://claude.ai/chat/0b7f3c52-1d4e-4a8b-9c6d-2f1e5a7b8c90"
        #expect(URLClassifier.classify(claude) == .url(.init(url: claude)))
    }
}

// MARK: N11–N13

@Suite struct OrcaBookkeepingTests {
    @Test func dryRunAndRealRunReportTheSameLocation() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "t")
            let code = try store.addLocation(ticketId: ticket.id, locator: .claudeCode(claude), source: .hook)
            let term = try store.addLocation(
                ticketId: ticket.id, locator: .orcaTerminal(.init(terminalHandle: "term_1", worktreeId: "w", tabId: "t", ptyId: "p")),
                source: .manual)
            let runner = FakeRunner()
            runner.on(switchArgv("term_1"), switchOK(tabId: "t", worktreeId: "w"))
            let resolver = makeResolver(runner)
            let planned = try resolver.planGo(ticketId: ticket.id, locationId: code.id, store: store)
            let real = try resolver.go(ticketId: ticket.id, locationId: code.id, store: store)
            #expect(planned.location.id == term.id)
            #expect(real.location.id == planned.location.id)
        }
    }

    @Test func recoveryPersistsListedTabIdWhenSwitchOnlyReportsTemporaryOne() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), switchStale)
        runner.on(listArgv, listOK([("term_new", "pty", "tab-new")]))
        runner.on(switchArgv("term_new"), switchOK(tabId: "pty:temp", worktreeId: "wt"))
        let stored = Locator.OrcaTerminal(terminalHandle: "term_old", worktreeId: "wt-old", tabId: "tab-old", ptyId: "pty")
        let loc = location(1, .orcaTerminal(stored))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(result.updatedLocator == .orcaTerminal(
            .init(terminalHandle: "term_new", worktreeId: "wt", tabId: "tab-new", ptyId: "pty")))
    }

    @Test func recoveryClearsOldTabIdWhenNewOneIsTemporary() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), switchStale)
        runner.on(listArgv, listOK([("term_new", "pty", "pty:temp")]))
        runner.on(switchArgv("term_new"), switchOK(tabId: "pty:temp", worktreeId: "wt"))
        let stored = Locator.OrcaTerminal(terminalHandle: "term_old", worktreeId: "wt", tabId: "tab-old", ptyId: "pty")
        let loc = location(1, .orcaTerminal(stored))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(result.updatedLocator == .orcaTerminal(
            .init(terminalHandle: "term_new", worktreeId: "wt", tabId: nil, ptyId: "pty")))
    }

    @Test func distinguishesNoMatchFromMatchWithSameHandle() {
        let same = FakeRunner()
        same.on(switchArgv("term_1"), switchStale)
        same.on(listArgv, listOK([("term_1", "pty", "tab")]))
        let loc = location(1, .orcaTerminal(.init(terminalHandle: "term_1", tabId: "tab", ptyId: "pty")))
        let sameResult = makeResolver(same).resolve(loc, among: [loc])
        #expect(!sameResult.ok && sameResult.message.contains("still listed"))

        let none = FakeRunner()
        none.on(switchArgv("term_1"), switchStale)
        none.on(listArgv, listOK([]))
        let noneResult = makeResolver(none).resolve(loc, among: [loc])
        #expect(!noneResult.ok && noneResult.message.contains("no listed terminal matches"))
    }

    @Test func toleratesListEntriesWithoutHandle() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), switchStale)
        runner.on(listArgv, CommandResult(exitCode: 0, stdout: """
            {"ok":true,"result":{"terminals":[{"ptyId":"broken"},{"handle":"term_new","ptyId":"pty","tabId":"tab"}]}}
            """))
        runner.on(switchArgv("term_new"), switchOK(tabId: "tab", worktreeId: "wt"))
        let loc = location(1, .orcaTerminal(.init(terminalHandle: "term_old", ptyId: "pty")))
        #expect(makeResolver(runner).resolve(loc, among: [loc]).ok)
    }

    @Test func mentionsTruncatedListWhenNothingMatches() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), switchStale)
        runner.on(listArgv, CommandResult(exitCode: 0, stdout: #"{"ok":true,"result":{"terminals":[],"truncated":true,"totalCount":900}}"#))
        let loc = location(1, .orcaTerminal(.init(terminalHandle: "term_old", ptyId: "pty")))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(!result.ok && result.message.contains("truncated"))
        #expect(runner.argvs.contains(listArgv))
    }

    @Test func toleratesNoiseBeforeJSON() {
        let runner = FakeRunner()
        let noisy = CommandResult(exitCode: 0, stdout: "(node:1) ExperimentalWarning: something\n" + switchOK(tabId: "tab", worktreeId: "wt").stdout)
        runner.on(switchArgv("term_1"), noisy)
        let loc = location(1, .orcaTerminal(.init(terminalHandle: "term_1", worktreeId: "wt", tabId: "tab", ptyId: "pty")))
        #expect(makeResolver(runner).resolve(loc, among: [loc]).ok)
    }

    @Test func recoveredHandleIsPersistedByGoAndFailedRecoveryIsNot() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "t")
            let stored = Locator.OrcaTerminal(terminalHandle: "term_old", worktreeId: "wt", tabId: "tab", ptyId: "pty")
            let term = try store.addLocation(ticketId: ticket.id, locator: .orcaTerminal(stored), source: .manual)

            let good = FakeRunner()
            good.on(switchArgv("term_old"), switchStale)
            good.on(listArgv, listOK([("term_new", "pty", "tab")]))
            good.on(switchArgv("term_new"), switchOK(tabId: "tab", worktreeId: "wt"))
            _ = try makeResolver(good).go(ticketId: ticket.id, store: store)
            let persisted = try store.locations(ticketId: ticket.id).first { $0.id == term.id }
            #expect(persisted?.locator == .orcaTerminal(.init(terminalHandle: "term_new", worktreeId: "wt", tabId: "tab", ptyId: "pty")))

            let bad = FakeRunner()
            bad.on(switchArgv("term_new"), switchStale)
            bad.on(listArgv, listOK([]))
            let failed = try makeResolver(bad).go(ticketId: ticket.id, store: store)
            #expect(!failed.ok)
            let untouched = try store.locations(ticketId: ticket.id).first { $0.id == term.id }
            #expect(untouched == persisted)
        }
    }
}
