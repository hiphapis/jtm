import Foundation
import Testing
@testable import WWIAppCore
@testable import WWICore

/// 임시 HOME과 가짜 앱 번들(`Where Was I.app/Contents/Helpers/wwi`)을 만들어 준다. 진짜 홈 폴더는 어떤 테스트도 건드리지 않는다.
private struct Sandbox {
    let root: String
    var home: String { root + "/home" }
    var helper: String { root + "/Apps/Where Was I.app/Contents/Helpers/wwi" }

    func setup(helper: Bool = true) -> CLISetup { CLISetup(home: home, helperPath: helper ? self.helper : nil) }
    var claudeSettings: String { home + "/.claude/settings.json" }
    var codexHooks: String { home + "/.codex/hooks.json" }
    var link: String { home + "/.local/bin/wwi" }

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
    let root = NSTemporaryDirectory() + "wwi-setup-tests-\(UUID().uuidString)"
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
            try FileManager.default.createSymbolicLink(atPath: box.link, withDestinationPath: "/nonexistent/old/Where Was I.app/Contents/Helpers/wwi")
            #expect(box.setup().linkState() == .otherTarget("/nonexistent/old/Where Was I.app/Contents/Helpers/wwi"))
            try FileManager.default.removeItem(atPath: box.link)
            try box.write("old copy", to: box.link)
            #expect(box.setup().linkState() == .notALink)
        }
    }

    @Test func aRelativeLinkToThisAppCountsAsOk() throws {
        try withSandbox { box in
            try FileManager.default.createDirectory(atPath: box.home + "/.local/bin", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: box.link, withDestinationPath: "../../../Apps/Where Was I.app/Contents/Helpers/wwi")
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

@Suite(.korean) struct SetupInstallTests {
    @Test func installLinksTheCLIAndWritesHooksWithTheStableLinkPath() throws {
        try withSandbox { box in
            let existing = #"{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}"#
            try box.write(existing, to: box.claudeSettings)

            let result = box.setup().install()

            #expect(result.ok, "\(result)")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.link) == box.helper)
            let claude = try #require(box.read(box.claudeSettings))
            #expect(claude.contains("\"theme\"") && claude.contains("echo mine"))  // 기존 설정은 그대로
            #expect(claude.contains(box.link))  // 훅은 번들 안 경로가 아니라 ~/.local/bin/wwi를 부른다
            #expect(!claude.contains("Contents/Helpers"))
            #expect(box.read(box.codexHooks)?.contains(box.link) == true)
            #expect(result.wroteCodexHooks)

            let backups = box.entries(in: box.home + "/.claude").filter { $0.contains(".wwi-backup-") }
            #expect(backups.count == 1)  // 기존 파일이 있었으니 백업이 하나
            #expect(box.read(box.home + "/.claude/" + backups[0]) == existing)
            #expect(box.entries(in: box.home + "/.codex").filter { $0.contains(".wwi-backup-") }.isEmpty)  // 새로 만든 파일은 백업이 없다

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
            try FileManager.default.createSymbolicLink(atPath: box.link, withDestinationPath: "/old/Where Was I.app/Contents/Helpers/wwi")
            #expect(box.setup().install().ok)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.link) == box.helper)

            try FileManager.default.removeItem(atPath: box.link)
            try box.write("my own wwi build", to: box.link)
            let result = box.setup().install()
            #expect(result.ok)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.link) == box.helper)
            let kept = box.entries(in: box.home + "/.local/bin").filter { $0.hasPrefix("wwi.wwi-backup-") }
            #expect(kept.count == 1 && box.read(box.home + "/.local/bin/" + kept[0]) == "my own wwi build")
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

    @Test func removingHooksTakesOnlyWwiEntriesOutAndKeepsTheLink() throws {
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
            #expect(box.entries(in: box.home + "/.claude").filter { $0.contains(".wwi-backup-") }.count == 2)  // 설치 때, 제거 때
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

@MainActor @Suite(.korean) struct SetupControllerTests {
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

// MARK: 옛 이름(JTM 0.1.x)에서 올라온 경우

@Suite(.korean) struct SetupLegacyTests {

    /// 0.1.x 설치 상태: 훅은 `~/.local/bin/jtm`을 부르고, 그 링크는 옛 앱 번들 안 CLI를 가리킨다.
    private func seedLegacy(_ box: Sandbox, link: Bool = true) throws {
        let oldLink = box.home + "/.local/bin/jtm"
        for agent in HookAgent.allCases {
            var config = try HookConfig.parse(Data("{}".utf8))
            try config.install(agent: agent, wwiPath: oldLink)
            try box.write(config.render().replacingOccurrences(of: "# wwi-managed", with: "# jtm-managed"), to: agent.defaultPath(home: box.home))
        }
        if link {
            try FileManager.default.createDirectory(atPath: box.home + "/.local/bin", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: oldLink, withDestinationPath: box.root + "/Apps/JTM.app/Contents/Helpers/jtm")
        }
    }

    @Test func legacyHooksCountAsNotSetUp() throws {
        try withSandbox { box in
            try seedLegacy(box)
            // 새 링크가 이미 이 앱을 가리켜도 옛 훅이 남아 있으면 설정이 필요하다(카드가 설치를 권한다).
            try FileManager.default.createDirectory(atPath: box.home + "/.local/bin", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: box.link, withDestinationPath: box.helper)
            let status = box.setup().status()
            #expect(status == SetupStatus(link: .ok, claude: .needsMigration, codex: .needsMigration, legacyLink: true))
            #expect(status.needsSetup && !status.hooksInstalledEverywhere)
        }
    }

    @Test func installMigratesHooksAndRemovesTheLegacyLink() throws {
        try withSandbox { box in
            try seedLegacy(box)

            let result = box.setup().install()

            #expect(result.ok, "\(result)")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.link) == box.helper)
            #expect(!box.exists(box.home + "/.local/bin/jtm") && (try? FileManager.default.destinationOfSymbolicLink(atPath: box.home + "/.local/bin/jtm")) == nil)
            #expect(result.lines.contains { $0.contains("~/.local/bin/jtm") })  // 설치 결과에 옛 링크를 지웠다고 알린다
            for agent in HookAgent.allCases {
                let text = try #require(box.read(agent.defaultPath(home: box.home)))
                #expect(!text.contains("jtm-managed"))
                #expect(text.components(separatedBy: "# wwi-managed").count - 1 == agent.events.count)  // 이벤트마다 하나
                #expect(text.contains(box.link))
            }
            #expect(box.setup().status() == SetupStatus(link: .ok, claude: .installed, codex: .installed))
            #expect(!box.setup().status().needsSetup)
        }
    }

    @Test func theLegacyLinkSurvivesAnInstallThatCouldNotMigrateEveryHook() throws {
        try withSandbox { box in
            try seedLegacy(box)
            let legacy = box.home + "/.local/bin/jtm"
            let target = box.root + "/Apps/JTM.app/Contents/Helpers/jtm"

            // 한쪽 설정 파일이 깨져 있으면 계획 단계에서 멈춘다: 아무것도 바뀌지 않고 옛 링크도 그대로다.
            let codexBefore = try #require(box.read(box.codexHooks))
            try box.write("{ not json", to: box.codexHooks)
            #expect(!box.setup().install().ok)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: legacy) == target)
            try box.write(codexBefore, to: box.codexHooks)

            // 첫 에이전트는 바꿨지만 둘째 쓰기가 실패하는 경우(Codex 폴더에 쓸 수 없다): 옛 훅이 아직 남았으니 링크를 지우지 않는다.
            let codexDirectory = box.home + "/.codex"
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: codexDirectory)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexDirectory) }
            let failed = box.setup().install()
            #expect(!failed.ok)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: legacy) == target)
            #expect(box.read(box.codexHooks)?.contains("jtm-managed") == true)
            #expect(!failed.lines.contains { $0.contains("~/.local/bin/jtm") })

            // 문제를 고치고 다시 실행하면 이전이 끝나고 그때 지운다.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexDirectory)
            let result = box.setup().install()
            #expect(result.ok, "\(result)")
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: legacy)) == nil)
            #expect(result.lines.contains { $0.contains("~/.local/bin/jtm") })
        }
    }

    @Test func aLegacyLinkRepointedToTheNewHelperIsStillOursAndGoesAfterMigration() throws {
        try withSandbox { box in
            try seedLegacy(box, link: false)
            // 설치 스크립트가 훅 이전에 실패했을 때 남기는 모양: `jtm` 링크가 새 앱의 `wwi`를 가리킨다.
            try FileManager.default.createDirectory(atPath: box.home + "/.local/bin", withIntermediateDirectories: true)
            let legacy = box.home + "/.local/bin/jtm"
            try FileManager.default.createSymbolicLink(atPath: legacy, withDestinationPath: box.helper)
            #expect(box.setup().status().legacyLink)

            let result = box.setup().install()

            #expect(result.ok, "\(result)")
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: legacy)) == nil)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.link) == box.helper)
            #expect(!box.setup().status().legacyLink)
        }
    }

    @Test func aHandMadeJtmFileOrForeignLinkIsLeftAlone() throws {
        try withSandbox { box in
            try FileManager.default.createDirectory(atPath: box.home + "/.local/bin", withIntermediateDirectories: true)
            let mine = box.home + "/.local/bin/jtm"
            try FileManager.default.createSymbolicLink(atPath: mine, withDestinationPath: "/usr/local/bin/my-own-tool")
            #expect(!box.setup().status().legacyLink)
            #expect(box.setup().install().ok)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: mine) == "/usr/local/bin/my-own-tool")

            try FileManager.default.removeItem(atPath: mine)
            try box.write("#!/bin/sh\n", to: mine)  // 일반 파일
            #expect(!box.setup().status().legacyLink)
            #expect(box.setup().install().ok)
            #expect(box.read(mine) == "#!/bin/sh\n")
        }
    }

    @Test func removingHooksTakesTheLegacyEntriesOutToo() throws {
        try withSandbox { box in
            try seedLegacy(box)
            let result = box.setup().uninstallHooks()
            #expect(result.ok, "\(result)")
            for agent in HookAgent.allCases {
                #expect(box.read(agent.defaultPath(home: box.home))?.contains("jtm-managed") == false)
            }
        }
    }
}
