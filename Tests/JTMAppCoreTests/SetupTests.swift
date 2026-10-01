import Foundation
import Testing
@testable import JTMAppCore
@testable import JTMCore

/// 임시 HOME과 가짜 앱 번들(`JTM.app/Contents/Helpers/jtm`)을 만들어 준다. 진짜 홈 폴더는 어떤 테스트도 건드리지 않는다.
private struct Sandbox {
    let root: String
    var home: String { root + "/home" }
    var helper: String { root + "/Apps/JTM.app/Contents/Helpers/jtm" }

    func setup(helper: Bool = true) -> CLISetup { CLISetup(home: home, helperPath: helper ? self.helper : nil) }
    var claudeSettings: String { home + "/.claude/settings.json" }
    var codexHooks: String { home + "/.codex/hooks.json" }
    var link: String { home + "/.local/bin/jtm" }

    func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func entries(in directory: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted() }
}

private func withSandbox<T>(
    agents: Set<HookAgent> = [.claude, .codex], _ body: (Sandbox) throws -> T
) throws -> T {
    let (box, cleanup) = try makeSandbox(agents: agents)
    defer { cleanup() }
    return try body(box)
}

private func withSandboxAsync<T>(
    isolation: isolated (any Actor)? = #isolation, agents: Set<HookAgent> = [.claude, .codex],
    _ body: (Sandbox) async throws -> T
) async throws -> T {
    let (box, cleanup) = try makeSandbox(agents: agents)
    defer { cleanup() }
    return try await body(box)
}

private func makeSandbox(agents: Set<HookAgent>) throws -> (Sandbox, () -> Void) {
    let root = NSTemporaryDirectory() + "jtm-setup-tests-\(UUID().uuidString)"
    let box = Sandbox(root: root)
    #expect(box.home != NSHomeDirectory())
    try FileManager.default.createDirectory(atPath: box.home, withIntermediateDirectories: true)
    try box.write("#!/bin/sh\n", to: box.helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.helper)
    for agent in agents { try FileManager.default.createDirectory(atPath: box.home + "/." + agent.rawValue, withIntermediateDirectories: true) }
    return (box, { try? FileManager.default.removeItem(atPath: root) })
}

@Suite struct SetupStatusTests {
    @Test func aFreshMachineNeedsSetup() throws {
        try withSandbox { box in
            let status = box.setup().status()
            #expect(status == SetupStatus(link: .missing, claude: .needsInstall, codex: .needsInstall))
            #expect(status.canInstall && status.needsSetup)
        }
    }

    @Test func withoutAnEmbeddedCLIThereIsNothingToOffer() throws {
        try withSandbox { box in
            let status = box.setup(helper: false).status()
            #expect(status.link == .noHelper && !status.canInstall && !status.needsSetup)
            let result = box.setup(helper: false).install()
            #expect(!result.ok && !box.exists(box.link) && !box.exists(box.claudeSettings))
        }
    }

    @Test func noClaudeAndNoCodexStillOffersTheLinkOnly() throws {
        try withSandbox(agents: []) { box in
            let status = box.setup().status()
            #expect(status == SetupStatus(link: .missing, claude: .notPresent, codex: .notPresent))
            #expect(status.needsSetup)
        }
    }

    @Test func aLinkIntoAnotherAppOrAPlainFileIsNotOk() throws {
        try withSandbox { box in
            try FileManager.default.createDirectory(atPath: box.home + "/.local/bin", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: box.link, withDestinationPath: "/nonexistent/old/JTM.app/Contents/Helpers/jtm")
            #expect(box.setup().linkState() == .otherTarget("/nonexistent/old/JTM.app/Contents/Helpers/jtm"))
            try FileManager.default.removeItem(atPath: box.link)
            try box.write("old copy", to: box.link)
            #expect(box.setup().linkState() == .notALink)
        }
    }

    @Test func aRelativeLinkToThisAppCountsAsOk() throws {
        try withSandbox { box in
            try FileManager.default.createDirectory(atPath: box.home + "/.local/bin", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: box.link, withDestinationPath: "../../../Apps/JTM.app/Contents/Helpers/jtm")
            #expect(box.setup().linkState() == .ok)
        }
    }

    @Test func aBrokenSettingsFileIsReportedNotInstalledOver() throws {
        try withSandbox { box in
            try box.write("{ not json", to: box.claudeSettings)
            guard case .unreadable(let reason) = box.setup().hooksState(.claude) else { Issue.record("expected unreadable"); return }
            #expect(reason.contains("~/.claude/settings.json"))
            #expect(box.setup().status().needsSetup)
        }
    }
}

@Suite struct SetupInstallTests {
    @Test func installLinksTheCLIAndWritesHooksWithTheStableLinkPath() throws {
        try withSandbox { box in
            let existing = #"{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}"#
            try box.write(existing, to: box.claudeSettings)

            let result = box.setup().install()

            #expect(result.ok, "\(result)")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.link) == box.helper)
            let claude = try #require(box.read(box.claudeSettings))
            #expect(claude.contains("\"theme\"") && claude.contains("echo mine"))  // 기존 설정은 그대로
            #expect(claude.contains(box.link))  // 훅은 번들 안 경로가 아니라 ~/.local/bin/jtm을 부른다
            #expect(!claude.contains("Contents/Helpers"))
            #expect(box.read(box.codexHooks)?.contains(box.link) == true)
            #expect(result.wroteCodexHooks)

            let backups = box.entries(in: box.home + "/.claude").filter { $0.contains(".jtm-backup-") }
            #expect(backups.count == 1)  // 기존 파일이 있었으니 백업이 하나
            #expect(box.read(box.home + "/.claude/" + backups[0]) == existing)
            #expect(box.entries(in: box.home + "/.codex").filter { $0.contains(".jtm-backup-") }.isEmpty)  // 새로 만든 파일은 백업이 없다

            #expect(box.setup().status() == SetupStatus(link: .ok, claude: .installed, codex: .installed))
            #expect(!box.setup().status().needsSetup)
        }
    }

    @Test func installingTwiceChangesNothingTheSecondTime() throws {
        try withSandbox { box in
            #expect(box.setup().install().ok)
            let before = (box.read(box.claudeSettings), box.read(box.codexHooks), box.entries(in: box.home + "/.claude"))
            let second = box.setup().install()
            #expect(second.ok && !second.wroteCodexHooks)
            #expect((box.read(box.claudeSettings), box.read(box.codexHooks), box.entries(in: box.home + "/.claude")) == before)
        }
    }

    @Test func installSkipsAgentsThatAreNotThereAndDoesNotCreateTheirFolders() throws {
        try withSandbox(agents: []) { box in
            let result = box.setup().install()
            #expect(result.ok && !result.wroteCodexHooks)
            #expect(box.exists(box.link))
            #expect(!box.exists(box.home + "/.claude") && !box.exists(box.home + "/.codex"))
            #expect(result.lines.contains { $0.contains("폴더가 없어서") })
        }
    }

    @Test func onlyTheAgentThatExistsGetsHooks() throws {
        try withSandbox(agents: [.claude]) { box in
            #expect(box.setup().install().ok)
            #expect(box.exists(box.claudeSettings) && !box.exists(box.home + "/.codex"))
            #expect(box.setup().status() == SetupStatus(link: .ok, claude: .installed, codex: .notPresent))
        }
    }

    @Test func aStaleLinkIsRepointedAndAPlainFileIsMovedAside() throws {
        try withSandbox { box in
            try FileManager.default.createDirectory(atPath: box.home + "/.local/bin", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: box.link, withDestinationPath: "/old/JTM.app/Contents/Helpers/jtm")
            #expect(box.setup().install().ok)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.link) == box.helper)

            try FileManager.default.removeItem(atPath: box.link)
            try box.write("my own jtm build", to: box.link)
            let result = box.setup().install()
            #expect(result.ok)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.link) == box.helper)
            let kept = box.entries(in: box.home + "/.local/bin").filter { $0.hasPrefix("jtm.jtm-backup-") }
            #expect(kept.count == 1 && box.read(box.home + "/.local/bin/" + kept[0]) == "my own jtm build")
        }
    }

    @Test func aBrokenSettingsFileAbortsBeforeAnythingIsWritten() throws {
        try withSandbox { box in
            try box.write("{ not json", to: box.claudeSettings)
            let result = box.setup().install()
            #expect(!result.ok)
            #expect(!box.exists(box.link) && !box.exists(box.codexHooks))  // 링크도, 다른 쪽 훅도 건드리지 않는다
            #expect(box.read(box.claudeSettings) == "{ not json")
            #expect(box.entries(in: box.home + "/.claude") == ["settings.json"])
        }
    }

    @Test func removingHooksTakesOnlyJtmEntriesOutAndKeepsTheLink() throws {
        try withSandbox { box in
            let existing = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}"#
            try box.write(existing, to: box.claudeSettings)
            #expect(box.setup().install().ok)

            let removal = box.setup().uninstallHooks()
            #expect(removal.ok, "\(removal)")
            let claude = try #require(box.read(box.claudeSettings))
            #expect(claude.contains("echo mine") && !claude.contains(box.link))
            #expect(box.exists(box.link))  // 링크는 남는다
            #expect(box.setup().status().claude == .needsInstall)
            #expect(box.entries(in: box.home + "/.claude").filter { $0.contains(".jtm-backup-") }.count == 2)  // 설치 때, 제거 때
        }
    }

    @Test func removingHooksOnAMachineWithoutThemIsANoop() throws {
        try withSandbox(agents: []) { box in
            let result = box.setup().uninstallHooks()
            #expect(result.ok && result.lines.count == 2)
            #expect(!box.exists(box.home + "/.claude") && !box.exists(box.home + "/.codex"))
        }
    }
}

@MainActor @Suite struct SetupControllerTests {
    private func controller(_ box: Sandbox, preferences: InMemorySetupPreferences = .init(), helper: Bool = true) -> SetupController {
        SetupController(setup: box.setup(helper: helper), preferences: preferences)
    }

    @Test func theCardShowsWhenSetupIsNeededAndLaterHidesItForThisRun() throws {
        try withSandbox { box in
            let setup = controller(box)
            #expect(setup.isVisible)
            guard case .offer = setup.mode else { Issue.record("expected the offer"); return }
            setup.later()
            #expect(!setup.isVisible)
            setup.show()  // 푸터 메뉴 "CLI·훅 설정…"
            #expect(setup.isVisible)
        }
    }

    @Test func theCardStaysHiddenWhenNothingIsNeededOrNothingCanBeInstalled() throws {
        try withSandbox { box in
            #expect(!controller(box, helper: false).isVisible)
            #expect(box.setup().install().ok)
            let setup = controller(box)
            #expect(!setup.isVisible)
            setup.show()
            guard case .allSet = setup.mode else { Issue.record("expected allSet"); return }
        }
    }

    @Test func installShowsTheResultAndTheCodexTrustNoticeThenDismisses() async throws {
        try await withSandboxAsync { box in
            let setup = controller(box)
            await setup.install()
            guard case .finished(let result, let action) = setup.mode else { Issue.record("expected finished"); return }
            #expect(action == .install && result.ok && result.wroteCodexHooks)
            #expect(!setup.status.needsSetup)
            setup.dismissResult()
            #expect(!setup.isVisible)
        }
    }

    @Test func installReportsFailureInsteadOfPretendingSuccess() async throws {
        try await withSandboxAsync { box in
            try box.write("{ not json", to: box.claudeSettings)
            let setup = controller(box)
            await setup.install()
            guard case .finished(let result, _) = setup.mode else { Issue.record("expected finished"); return }
            #expect(!result.ok && result.error != nil)
        }
    }

    @Test func removingHooksSilencesTheCardUntilTheNextInstall() async throws {
        try await withSandboxAsync { box in
            let preferences = InMemorySetupPreferences()
            let setup = controller(box, preferences: preferences)
            await setup.install()
            setup.dismissResult()
            await setup.removeHooks()
            guard case .finished(_, let action) = setup.mode else { Issue.record("expected finished"); return }
            #expect(action == .removeHooks && preferences.hooksRemovedByUser)
            setup.dismissResult()
            #expect(setup.status.needsSetup && !setup.isVisible)  // 일부러 제거했으니 다시 조르지 않는다
            // 다음 실행(새 컨트롤러)에서도 마찬가지.
            #expect(!controller(box, preferences: preferences).isVisible)
            setup.show()
            await setup.install()
            #expect(!preferences.hooksRemovedByUser)
        }
    }
}
