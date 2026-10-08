import Foundation
import Testing
@testable import WWICore

/// 실제 프로세스를 띄우는 유일한 테스트: `/bin/sleep`과 `/bin/echo`만 쓴다(open/orca는 호출하지 않는다).
@Suite struct ProcessRunnerTests {
    @Test func killsHungCommandAndReportsTimeout() {
        let started = Date()
        let result = ProcessRunner().run(["/bin/sleep", "30"], stdin: nil, timeout: 0.3)
        #expect(result.exitCode == 124)
        #expect(result.timedOut)
        #expect(result.stderr.contains("timed out"))
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func returnsOutputAndExitCodeOfFastCommand() {
        let ok = ProcessRunner().run(["/bin/echo", "hello"], stdin: nil, timeout: 5)
        #expect(ok.succeeded && ok.stdout == "hello\n")
        let failed = ProcessRunner().run(["/bin/sh", "-c", "echo oops >&2; exit 3"], stdin: nil, timeout: 5)
        #expect(failed.exitCode == 3 && failed.stderr == "oops\n")
    }

    @Test func feedsStdin() {
        let result = ProcessRunner().run(["/bin/cat"], stdin: "piped text", timeout: 5)
        #expect(result.succeeded && result.stdout == "piped text")
    }

    @Test func reportsMissingExecutableAsExit127() {
        let result = ProcessRunner().run(["definitely-not-a-command-wwi"], stdin: nil, timeout: 5)
        #expect(result.exitCode == 127)
    }
}

@Suite struct TimeoutBudgetTests {
    @Test func resolverPassesShortTimeoutToOpenAndLongerToOrca() {
        let runner = FakeRunner()
        let url = location(1, .url(.init(url: "https://example.com")))
        _ = Resolver(runner: runner, orcaCommand: "/fake/orca").resolve(url, among: [url])
        #expect(runner.calls.map(\.timeout) == [3])

        let orcaRunner = FakeRunner()
        orcaRunner.on(["/fake/orca", "terminal", "switch"], switchOK(tabId: "t", worktreeId: "w"))
        let terminal = location(2, .orcaTerminal(.init(terminalHandle: "h", worktreeId: "w", tabId: "t", ptyId: "p")))
        _ = Resolver(runner: orcaRunner, orcaCommand: "/fake/orca").resolve(terminal, among: [terminal])
        #expect(orcaRunner.calls.map(\.timeout) == [3, 8])
    }

    @Test func timedOutOpenIsReportedAsFailure() {
        let runner = FakeRunner()
        runner.on(["open"], CommandResult(exitCode: 124, stderr: "timed out after 3s"))
        let url = location(1, .url(.init(url: "https://example.com")))
        let result = Resolver(runner: runner, orcaCommand: nil).resolve(url, among: [url])
        #expect(!result.ok)
        #expect(result.message.contains("timed out"))
    }
}
