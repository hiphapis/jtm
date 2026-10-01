import Foundation
import Testing
@testable import JTMCore

@Suite struct ResolverKindTests {
    @Test func codexThreadOpensCodexScheme() {
        let runner = FakeRunner()
        let loc = location(1, .codexThread(.init(threadId: "th-1")))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(result.ok)
        #expect(runner.argvs == [["open", "codex://threads/th-1"]])
    }

    @Test func chatgptOpensCodexSchemeWithChatId() {
        let runner = FakeRunner()
        let loc = location(1, .chatgptChat(.init(chatId: "abc", url: "https://chatgpt.com/g/g-p-1-x/c/abc")))
        #expect(makeResolver(runner).resolve(loc, among: [loc]).ok)
        #expect(runner.argvs == [["open", "codex://threads/abc"]])
    }

    @Test func chatgptFallsBackToWebURLWhenAppLinkFails() {
        let runner = FakeRunner()
        runner.on(["open", "codex://threads/abc"], CommandResult(exitCode: 1, stderr: "no handler"))
        let loc = location(1, .chatgptChat(.init(chatId: "abc", url: "https://chatgpt.com/c/abc")))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(result.ok)
        #expect(runner.argvs == [["open", "codex://threads/abc"], ["open", "https://chatgpt.com/c/abc"]])
    }

    @Test func chatgptReportsFailureWhenFallbackAlsoFails() {
        let runner = FakeRunner()
        runner.on(["open"], CommandResult(exitCode: 1, stderr: "boom"))
        let loc = location(1, .chatgptChat(.init(chatId: "abc", url: "https://chatgpt.com/c/abc")))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(!result.ok)
        #expect(result.message.contains("boom"))
    }

    @Test func claudeChatOpensWebURL() {
        let runner = FakeRunner()
        let loc = location(1, .claudeChat(.init(chatUuid: "u", url: "https://claude.ai/chat/u")))
        #expect(makeResolver(runner).resolve(loc, among: [loc]).ok)
        #expect(runner.argvs == [["open", "https://claude.ai/chat/u"]])
    }

    @Test func urlOpensURLAndReportsFailure() {
        let runner = FakeRunner()
        runner.on(["open"], CommandResult(exitCode: 1, stderr: "nope"))
        let loc = location(1, .url(.init(url: "https://example.com")))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(runner.argvs == [["open", "https://example.com"]])
        #expect(!result.ok)
        #expect(result.message.contains("nope"))
    }

    // MARK: claude_code

    @Test func claudeCodeDelegatesToOrcaTerminalOfSameTicket() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_1"), switchOK(tabId: "tab", worktreeId: "wt"))
        runner.on(listArgv, listOK([("term_1", "pty", "tab")]))
        let code = location(1, .claudeCode(.init(sessionId: "s1", cwd: "/work")))
        let terminal = location(2, .orcaTerminal(.init(terminalHandle: "term_1")))
        let result = makeResolver(runner).resolve(code, among: [code, terminal])
        #expect(result.ok)
        #expect(result.location.id == 2)
        #expect(!result.copiedToClipboard)
        #expect(runner.argvs.first == openOrca)
        #expect(runner.argvs.contains(switchArgv("term_1")))
        #expect(!runner.argvs.contains { $0 == ["pbcopy"] })
    }

    @Test func claudeCodeCopiesResumeCommandWithoutOrcaTerminal() {
        let runner = FakeRunner()
        let code = location(1, .claudeCode(.init(sessionId: "s1", cwd: "/work/it's here")))
        let result = makeResolver(runner).resolve(code, among: [code])
        #expect(result.ok)
        #expect(result.message == "copied resume command")
        #expect(result.copiedToClipboard)
        #expect(runner.calls.map(\.argv) == [["pbcopy"]])
        #expect(runner.calls.first?.stdin == #"cd '/work/it'\''s here' && claude --resume 's1'"#)
    }

    @Test func claudeCodeClipboardFailureIsReported() {
        let runner = FakeRunner()
        runner.on(["pbcopy"], CommandResult(exitCode: 1, stderr: "denied"))
        let code = location(1, .claudeCode(.init(sessionId: "s1", cwd: "/w")))
        #expect(!makeResolver(runner).resolve(code, among: [code]).ok)
    }

    // MARK: primary location

    @Test func chooseIsNilWithoutLocations() {
        #expect(Resolver.choose(from: []) == nil)
    }

    @Test func choosePrefersOrcaTerminalEvenIfOlder() {
        let url = location(1, .url(.init(url: "u")), seen: 2_000)
        let terminal = location(2, .orcaTerminal(.init(terminalHandle: "t")), seen: 1_000)
        #expect(Resolver.choose(from: [url, terminal])?.id == 2)
    }

    @Test func chooseTakesMostRecentlySeenOtherwise() {
        let old = location(1, .url(.init(url: "old")), seen: 1_000)
        let recent = location(2, .codexThread(.init(threadId: "t")), seen: 3_000)
        let mid = location(3, .url(.init(url: "mid")), seen: 2_000)
        #expect(Resolver.choose(from: [old, recent, mid])?.id == 2)
    }

    @Test func chooseBreaksTiesByLowestId() {
        let a = location(5, .url(.init(url: "a")), seen: 1_000)
        let b = location(4, .url(.init(url: "b")), seen: 1_000)
        #expect(Resolver.choose(from: [a, b])?.id == 4)
    }

    @Test func chooseKeepsAgentSessionsAheadOfANewerChatOrURL() {
        let thread = location(1, .codexThread(.init(threadId: "t")), seen: 1_000)
        let chat = location(2, .chatgptChat(.init(chatId: "c", url: "https://chatgpt.com/c/c")), seen: 9_000)
        let url = location(3, .url(.init(url: "u")), seen: 9_500)
        #expect(Resolver.choose(from: [thread, chat, url])?.id == 1)
        let code = location(4, .claudeCode(.init(sessionId: "s", cwd: "/w")), seen: 500)
        #expect(Resolver.choose(from: [chat, url, code])?.id == 4)
        // 세션 위치끼리는 가장 최근 것, 그리고 Orca 터미널이 있으면 그것이 먼저다.
        #expect(Resolver.choose(from: [thread, code, chat])?.id == 1)
        let terminal = location(5, .orcaTerminal(.init(terminalHandle: "t")), seen: 1)
        #expect(Resolver.choose(from: [thread, chat, terminal])?.id == 5)
        // 세션이 없으면 예전처럼 가장 최근 것.
        #expect(Resolver.choose(from: [chat, url])?.id == 3)
    }

    @Test func choosePicksMostRecentAmongOrcaTerminals() {
        let a = location(1, .orcaTerminal(.init(terminalHandle: "a")), seen: 1_000)
        let b = location(2, .orcaTerminal(.init(terminalHandle: "b")), seen: 2_000)
        #expect(Resolver.choose(from: [a, b])?.id == 2)
    }

    // MARK: plan (dry-run)

    @Test func planListsArgvWithoutRunningAnything() throws {
        let runner = FakeRunner()
        let resolver = makeResolver(runner)
        let chat = location(1, .chatgptChat(.init(chatId: "abc", url: "https://chatgpt.com/c/abc")))
        let plan = try resolver.plan(chat, among: [chat])
        #expect(plan.map(\.argv) == [["open", "codex://threads/abc"], ["open", "https://chatgpt.com/c/abc"]])

        let terminal = location(2, .orcaTerminal(.init(terminalHandle: "term_1")))
        #expect(try resolver.plan(terminal, among: [terminal]).map(\.argv) == [openOrca, switchArgv("term_1"), listArgv])

        let code = location(3, .claudeCode(.init(sessionId: "s", cwd: "/w")))
        #expect(try resolver.plan(code, among: [code]) == [PlannedCommand(["pbcopy"], stdin: "cd '/w' && claude --resume 's'")])
        #expect(runner.calls.isEmpty)
    }
}

@Suite struct OrcaTerminalTests {
    let full = Locator.OrcaTerminal(
        terminalHandle: "term_1", worktreeId: "wt", tabId: "tab", ptyId: "pty")

    @Test func switchesAfterOpeningOrca() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_1"), switchOK(tabId: "tab", worktreeId: "wt"))
        let loc = location(1, .orcaTerminal(full))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(result.ok)
        #expect(result.updatedLocator == nil)
        #expect(runner.argvs == [openOrca, switchArgv("term_1")])
    }

    @Test func persistsFocusIdsAndFillsPtyIdFromListing() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_1"), switchOK(tabId: "tab", worktreeId: "wt"))
        runner.on(listArgv, listOK([("term_other", "pty-o", "tab-o"), ("term_1", "pty-1", "tab")]))
        let loc = location(1, .orcaTerminal(.init(terminalHandle: "term_1")))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(result.ok)
        #expect(result.updatedLocator == .orcaTerminal(
            .init(terminalHandle: "term_1", worktreeId: "wt", tabId: "tab", ptyId: "pty-1")))
        #expect(runner.argvs == [openOrca, switchArgv("term_1"), listArgv])
    }

    @Test func doesNotPersistTemporaryPtyTabId() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_1"), switchOK(tabId: "pty:repo", worktreeId: "wt"))
        let loc = location(1, .orcaTerminal(.init(terminalHandle: "term_1", ptyId: "pty")))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(result.updatedLocator == .orcaTerminal(.init(terminalHandle: "term_1", worktreeId: "wt", tabId: nil, ptyId: "pty")))
    }

    @Test func recoversStaleHandleByPtyId() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), switchStale)
        runner.on(listArgv, listOK([("term_x", "pty-x", "tab-x"), ("term_new", "pty", "tab-new")]))
        runner.on(switchArgv("term_new"), switchOK(tabId: "tab-new", worktreeId: "wt2"))
        let stored = Locator.OrcaTerminal(terminalHandle: "term_old", worktreeId: "wt", tabId: "tab", ptyId: "pty")
        let loc = location(1, .orcaTerminal(stored))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(result.ok)
        #expect(result.message.contains("term_new") && result.message.contains("term_old"))
        #expect(result.updatedLocator == .orcaTerminal(
            .init(terminalHandle: "term_new", worktreeId: "wt2", tabId: "tab-new", ptyId: "pty")))
        #expect(runner.argvs == [openOrca, switchArgv("term_old"), listArgv, switchArgv("term_new")])
    }

    @Test func ptyIdMatchWinsOverTabId() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), switchStale)
        runner.on(listArgv, listOK([("by_tab", "pty-other", "tab"), ("by_pty", "pty", "tab-z")]))
        let stored = Locator.OrcaTerminal(terminalHandle: "term_old", tabId: "tab", ptyId: "pty")
        let loc = location(1, .orcaTerminal(stored))
        _ = makeResolver(runner).resolve(loc, among: [loc])
        #expect(runner.argvs.last == switchArgv("by_pty"))
    }

    @Test func recoversStaleHandleByTabIdWhenPtyIdUnknown() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), switchStale)
        runner.on(listArgv, listOK([("term_x", "pty-x", "tab-x"), ("term_new", "pty-new", "tab")]))
        runner.on(switchArgv("term_new"), switchOK(tabId: "tab", worktreeId: "wt"))
        let loc = location(1, .orcaTerminal(.init(terminalHandle: "term_old", tabId: "tab")))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(result.ok)
        #expect(result.updatedLocator == .orcaTerminal(
            .init(terminalHandle: "term_new", worktreeId: "wt", tabId: "tab", ptyId: "pty-new")))
    }

    @Test func ignoresTemporaryPtyTabIds() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), switchStale)
        runner.on(listArgv, listOK([("term_orphan", "pty-other", "pty:repo")]))
        let loc = location(1, .orcaTerminal(.init(terminalHandle: "term_old", tabId: "pty:repo")))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(!result.ok)
        #expect(result.message.contains("orca search"))
        #expect(runner.argvs == [openOrca, switchArgv("term_old"), listArgv])
    }

    @Test func failsWithSearchHintWhenNothingMatches() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), switchStale)
        runner.on(listArgv, listOK([("term_x", "pty-x", "tab-x")]))
        let loc = location(1, .orcaTerminal(.init(terminalHandle: "term_old", tabId: "tab", ptyId: "pty")))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(!result.ok)
        #expect(result.message.contains("terminal_handle_stale") && result.message.contains("orca search"))
        #expect(result.updatedLocator == nil)
    }

    @Test func failsWhenListingAlsoFails() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_old"), CommandResult(exitCode: 1, stderr: "Orca is not running"))
        runner.on(listArgv, CommandResult(exitCode: 1, stderr: "Orca is not running"))
        let loc = location(1, .orcaTerminal(.init(terminalHandle: "term_old", ptyId: "pty")))
        let result = makeResolver(runner).resolve(loc, among: [loc])
        #expect(!result.ok)
        #expect(result.message.contains("Orca is not running"))
    }

    @Test func treatsOkFalseAsFailureEvenWithExitZero() {
        let runner = FakeRunner()
        runner.on(switchArgv("term_1"), CommandResult(exitCode: 0, stdout: #"{"ok":false,"error":{"code":"nope"}}"#))
        runner.on(listArgv, listOK([]))
        let loc = location(1, .orcaTerminal(full))
        #expect(!makeResolver(runner).resolve(loc, among: [loc]).ok)
    }

    @Test func missingOrcaCLIFailsClearlyWithoutRunningAnything() {
        let runner = FakeRunner()
        let resolver = makeResolver(runner, orcaCommand: nil)
        let loc = location(1, .orcaTerminal(full))
        let result = resolver.resolve(loc, among: [loc])
        #expect(!result.ok)
        #expect(result.message.contains("ORCA_CLI_COMMAND"))
        #expect(runner.calls.isEmpty)
        #expect(throws: ResolveError.self) { try resolver.plan(loc, among: [loc]) }
    }
}

@Suite struct OrcaCLILocateTests {
    @Test func environmentOverrideWins() {
        let found = OrcaCLI.locate(environment: ["ORCA_CLI_COMMAND": "/custom/orca", "PATH": "/bin"], isExecutable: { _ in true })
        #expect(found == "/custom/orca")
    }

    @Test func findsOrcaOnPath() {
        let found = OrcaCLI.locate(
            environment: ["PATH": "/a:/b:/c"], isExecutable: { $0 == "/b/orca" })
        #expect(found == "/b/orca")
    }

    @Test func fallsBackToUsrLocalBin() {
        let found = OrcaCLI.locate(environment: ["PATH": "/a"], isExecutable: { $0 == OrcaCLI.fallbackPath })
        #expect(found == "/usr/local/bin/orca")
    }

    @Test func returnsNilWhenNotFound() {
        #expect(OrcaCLI.locate(environment: ["PATH": "/a"], isExecutable: { _ in false }) == nil)
    }
}

@Suite struct GoTests {
    @Test func successPersistsLocatorAndBumpsOnlyUpdatedAt() throws {
        try withStore { store, clock, _ in
            let ticket = try store.createTicket(title: "t")
            let terminal = try store.addLocation(
                ticketId: ticket.id, locator: .orcaTerminal(.init(terminalHandle: "term_1")), source: .manual)
            try store.addLocation(ticketId: ticket.id, locator: .claudeCode(.init(sessionId: "s", cwd: "/w")), source: .hook)
            let runner = FakeRunner()
            runner.on(switchArgv("term_1"), switchOK(tabId: "tab", worktreeId: "wt"))
            runner.on(listArgv, listOK([("term_1", "pty", "tab")]))
            clock.advance(120)

            let result = try makeResolver(runner).go(ticketId: ticket.id, store: store)

            #expect(result.ok)
            let stored = try store.locations(ticketId: ticket.id).first { $0.id == terminal.id }
            #expect(stored?.locator == .orcaTerminal(.init(terminalHandle: "term_1", worktreeId: "wt", tabId: "tab", ptyId: "pty")))
            let after = try store.getTicket(id: ticket.id)
            #expect(after.updatedAt == clock.current)
            #expect(after.lastActivityAt == ticket.lastActivityAt)
        }
    }

    @Test func failureLeavesTicketAndLocationsUntouched() throws {
        try withStore { store, clock, _ in
            let ticket = try store.createTicket(title: "t")
            try store.addLocation(ticketId: ticket.id, locator: .url(.init(url: "https://x.example")), source: .manual)
            let runner = FakeRunner()
            runner.on(["open"], CommandResult(exitCode: 1, stderr: "bad"))
            clock.advance(120)

            let result = try makeResolver(runner).go(ticketId: ticket.id, store: store)

            #expect(!result.ok)
            #expect(try store.getTicket(id: ticket.id) == ticket)
        }
    }

    @Test func locationOverrideBeatsPrimary() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "t")
            try store.addLocation(ticketId: ticket.id, locator: .orcaTerminal(.init(terminalHandle: "term_1")), source: .manual)
            let url = try store.addLocation(ticketId: ticket.id, locator: .url(.init(url: "https://x.example")), source: .manual)
            let runner = FakeRunner()

            let result = try makeResolver(runner).go(ticketId: ticket.id, locationId: url.id, store: store)

            #expect(result.ok)
            #expect(runner.argvs == [["open", "https://x.example"]])
        }
    }

    @Test func locationFromAnotherTicketIsRejected() throws {
        try withStore { store, _, _ in
            let a = try store.createTicket(title: "a")
            let b = try store.createTicket(title: "b")
            try store.addLocation(ticketId: a.id, locator: .url(.init(url: "https://a.example")), source: .manual)
            let foreign = try store.addLocation(ticketId: b.id, locator: .url(.init(url: "https://b.example")), source: .manual)
            let runner = FakeRunner()
            #expect(throws: ResolveError.self) {
                try makeResolver(runner).go(ticketId: a.id, locationId: foreign.id, store: store)
            }
            #expect(runner.calls.isEmpty)
        }
    }

    @Test func ticketWithoutLocationsThrows() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "t")
            #expect(throws: ResolveError.self) { try makeResolver(FakeRunner()).go(ticketId: ticket.id, store: store) }
            #expect(throws: ResolveError.self) { try makeResolver(FakeRunner()).planGo(ticketId: ticket.id, store: store) }
        }
    }

    @Test func unknownTicketThrowsStoreError() throws {
        try withStore { store, _, _ in
            #expect(throws: StoreError.self) { try makeResolver(FakeRunner()).go(ticketId: 9, store: store) }
        }
    }

    @Test func planGoUsesPrimaryLocationAndRunsNothing() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "t")
            try store.addLocation(ticketId: ticket.id, locator: .url(.init(url: "https://x.example")), source: .manual)
            try store.addLocation(ticketId: ticket.id, locator: .orcaTerminal(.init(terminalHandle: "term_1")), source: .manual)
            let runner = FakeRunner()
            let planned = try makeResolver(runner).planGo(ticketId: ticket.id, store: store)
            #expect(planned.location.kind == .orcaTerminal)
            #expect(planned.commands.map(\.argv) == [openOrca, switchArgv("term_1"), listArgv])
            #expect(runner.calls.isEmpty)
        }
    }

    @Test func updateLocationRewritesLocatorOnly() throws {
        try withStore { store, clock, _ in
            let ticket = try store.createTicket(title: "t")
            let added = try store.addLocation(
                ticketId: ticket.id, locator: .orcaTerminal(.init(terminalHandle: "old")), source: .manual)
            clock.advance(60)
            let updated = try store.updateLocation(id: added.id, locator: .orcaTerminal(.init(terminalHandle: "new")))
            #expect(updated.locator == .orcaTerminal(.init(terminalHandle: "new")))
            #expect(updated.lastSeenAt == added.lastSeenAt)
            #expect(throws: StoreError.self) { try store.updateLocation(id: 99, locator: .url(.init(url: "u"))) }
        }
    }
}
