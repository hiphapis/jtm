import Foundation
import Testing
@testable import WWICore

private let wwiPath = "/opt/wwi/bin/wwi"

/// 테스트마다 고유한 임시 디렉터리. 실제 `~/.claude`, `~/.codex`는 어떤 테스트도 건드리지 않는다.
private func withTempDir<T>(_ body: (String) throws -> T) throws -> T {
    let directory = NSTemporaryDirectory() + "wwi-hooks-tests-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    return try body(directory)
}

private func write(_ text: String, to path: String, mode: Int = 0o644) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
}

private func read(_ path: String) throws -> String {
    String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
}

private func backups(in directory: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.contains(".wwi-backup-") }.sorted()
}

@Suite struct HookInstallerTests {
    @Test func planReadsButNeverWrites() throws {
        try withTempDir { dir in
            let path = dir + "/settings.json"
            try write(HooksFixtures.claudeSettings, to: path)
            let plan = try HookInstaller.plan(.install, agent: .claude, path: path, wwiPath: wwiPath)
            #expect(plan.changes.count == HookAgent.claude.events.count)
            #expect(plan.before == HooksFixtures.claudeSettings)
            #expect(plan.after != plan.before)
            #expect(try read(path) == HooksFixtures.claudeSettings)
            #expect(try backups(in: dir).isEmpty)
        }
    }

    @Test func applyMakesTimestampedBackupAndWritesAtomically() throws {
        try withTempDir { dir in
            let path = dir + "/settings.json"
            try write(HooksFixtures.claudeSettings, to: path, mode: 0o600)
            var plan = try HookInstaller.plan(.install, agent: .claude, path: path, wwiPath: wwiPath)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            try HookInstaller.apply(&plan, now: now)

            #expect(plan.written)
            let backupName = try #require(try backups(in: dir).first)
            #expect(backupName.range(of: #"^settings\.json\.wwi-backup-\d{8}-\d{6}$"#, options: .regularExpression) != nil)
            #expect(plan.backupPath == dir + "/" + backupName)
            #expect(try read(dir + "/" + backupName) == HooksFixtures.claudeSettings)
            #expect(try read(path) == plan.after)
            // rename으로 inode가 바뀌어도 권한은 유지, 임시 파일은 남지 않는다.
            let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir).allSatisfy { !$0.contains("wwi-tmp") })
        }
    }

    @Test func secondInstallChangesNothingAndMakesNoBackup() throws {
        try withTempDir { dir in
            let path = dir + "/hooks.json"
            try write(HooksFixtures.codexHooks, to: path)
            var first = try HookInstaller.plan(.install, agent: .codex, path: path, wwiPath: wwiPath)
            try HookInstaller.apply(&first)
            let afterFirst = try read(path)

            var second = try HookInstaller.plan(.install, agent: .codex, path: path, wwiPath: wwiPath)
            #expect(second.isNoop)
            try HookInstaller.apply(&second)
            #expect(!second.written)
            #expect(try read(path) == afterFirst)
            #expect(try backups(in: dir).count == 1)
        }
    }

    @Test func backupNamesDoNotCollideWithinTheSameSecond() throws {
        try withTempDir { dir in
            let path = dir + "/hooks.json"
            try write(HooksFixtures.codexHooks, to: path)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var install = try HookInstaller.plan(.install, agent: .codex, path: path, wwiPath: wwiPath)
            try HookInstaller.apply(&install, now: now)
            var uninstall = try HookInstaller.plan(.uninstall, agent: .codex, path: path, wwiPath: wwiPath)
            try HookInstaller.apply(&uninstall, now: now)

            #expect(try backups(in: dir).count == 2)
            #expect(install.backupPath != uninstall.backupPath)
            // 첫 백업은 원본, 둘째 백업은 설치 직후 상태.
            #expect(try read(try #require(install.backupPath)) == HooksFixtures.codexHooks)
            #expect(try read(try #require(uninstall.backupPath)) == install.after)
            #expect(try read(path) == HooksFixtures.codexHooks)
        }
    }

    @Test func missingFileIsCreatedWithoutBackupAndParentsAreMade() throws {
        try withTempDir { dir in
            let path = dir + "/nested/.codex/hooks.json"
            var plan = try HookInstaller.plan(.install, agent: .codex, path: path, wwiPath: wwiPath)
            #expect(!plan.existed)
            try HookInstaller.apply(&plan)
            #expect(plan.backupPath == nil)
            let config = try HookConfig.parse(Data(try read(path).utf8))
            #expect(try config.status(agent: .codex, wwiPath: wwiPath).allSatisfy { $0.state == .installed })
            #expect(try read(path).hasSuffix("}\n"))
        }
    }

    @Test func uninstallOnMissingFileDoesNotCreateIt() throws {
        try withTempDir { dir in
            let path = dir + "/hooks.json"
            var plan = try HookInstaller.plan(.uninstall, agent: .codex, path: path, wwiPath: wwiPath)
            #expect(plan.isNoop)
            try HookInstaller.apply(&plan)
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    @Test func invalidJSONFailsBeforeAnythingIsWritten() throws {
        try withTempDir { dir in
            let path = dir + "/settings.json"
            try write("{ \"hooks\": ", to: path)
            #expect(throws: HookFileError.self) { try HookInstaller.plan(.install, agent: .claude, path: path, wwiPath: wwiPath) }
            #expect(try read(path) == "{ \"hooks\": ")
            #expect(try backups(in: dir).isEmpty)
        }
    }

    @Test func refusesToOverwriteAFileThatChangedAfterPlanning() throws {
        try withTempDir { dir in
            let path = dir + "/settings.json"
            try write(HooksFixtures.claudeSettings, to: path)
            var plan = try HookInstaller.plan(.install, agent: .claude, path: path, wwiPath: wwiPath)
            try write("{\"someone\": \"else\"}\n", to: path)
            #expect(throws: HookFileError.self) { try HookInstaller.apply(&plan) }
            #expect(try read(path) == "{\"someone\": \"else\"}\n")
            #expect(try backups(in: dir).isEmpty)
        }
    }

    /// N8: 임시 파일을 다 쓴 뒤 rename 직전에 다른 프로세스가 원본을 바꿨으면, 그 변경을 덮어쓰지 않고 백업·임시 파일도 남기지 않는다.
    @Test func aChangeMadeJustBeforeTheRenameIsNotOverwritten() throws {
        try withTempDir { dir in
            let path = dir + "/settings.json"
            try write(HooksFixtures.claudeSettings, to: path)
            var plan = try HookInstaller.plan(.install, agent: .claude, path: path, wwiPath: wwiPath)
            #expect(throws: HookFileError.self) {
                try HookInstaller.apply(&plan, beforeRename: { try? write("{\"late\": true}\n", to: path) })
            }
            #expect(try read(path) == "{\"late\": true}\n")
            #expect(try backups(in: dir).isEmpty)
            #expect(plan.backupPath == nil && !plan.written)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["settings.json"])  // 임시 파일이 남지 않았다
        }
    }

    @Test func aFileThatAppearsJustBeforeTheRenameIsNotOverwritten() throws {
        try withTempDir { dir in
            let path = dir + "/new/settings.json"
            var plan = try HookInstaller.plan(.install, agent: .claude, path: path, wwiPath: wwiPath)
            #expect(!plan.existed)
            #expect(throws: HookFileError.self) {
                try HookInstaller.apply(&plan, beforeRename: { try? write("{}\n", to: path) })
            }
            #expect(try read(path) == "{}\n")
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir + "/new") == ["settings.json"])
        }
    }

    /// N8: 임시 파일은 원본 권한으로 만든다. 토큰이 든 0600 설정이 잠깐이라도 0644로 놓이지 않는다.
    @Test func theTemporaryFileHasTheOriginalModeBeforeItIsRenamed() throws {
        for mode in [0o600, 0o644, 0o640] {
            try withTempDir { dir in
                let path = dir + "/settings.json"
                try write(HooksFixtures.claudeSettings, to: path, mode: mode)
                var plan = try HookInstaller.plan(.install, agent: .claude, path: path, wwiPath: wwiPath)
                nonisolated(unsafe) var tempModes: [Int] = []
                try HookInstaller.apply(&plan, beforeRename: {
                    let temps = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.contains(".wwi-tmp-") }
                    tempModes = temps.compactMap {
                        (try? FileManager.default.attributesOfItem(atPath: dir + "/" + $0)[.posixPermissions] as? NSNumber)?.intValue
                    }
                })
                #expect(tempModes == [mode], "original \(String(mode, radix: 8))")
                let final = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
                #expect(final == mode)
            }
        }
    }

    @Test func writesThroughASymlinkInsteadOfReplacingIt() throws {
        try withTempDir { dir in
            let real = dir + "/dotfiles/settings.json"
            try FileManager.default.createDirectory(atPath: dir + "/dotfiles", withIntermediateDirectories: true)
            try write(HooksFixtures.claudeSettings, to: real)
            let link = dir + "/settings.json"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "dotfiles/settings.json")

            var plan = try HookInstaller.plan(.install, agent: .claude, path: link, wwiPath: wwiPath)
            try HookInstaller.apply(&plan)

            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == "dotfiles/settings.json")
            #expect(try read(real) == plan.after)
            #expect(try backups(in: dir + "/dotfiles").count == 1)
        }
    }

    @Test func fullRoundTripRestoresTheOriginalFiles() throws {
        try withTempDir { dir in
            for (name, text, agent) in [("settings.json", HooksFixtures.claudeSettings, HookAgent.claude),
                                        ("hooks.json", HooksFixtures.codexHooks, .codex)] {
                let path = dir + "/" + name
                try write(text, to: path)
                for operation in [HookFilePlan.Operation.install, .uninstall] {
                    var plan = try HookInstaller.plan(operation, agent: agent, path: path, wwiPath: wwiPath)
                    try HookInstaller.apply(&plan)
                }
                #expect(try read(path) == text)
            }
        }
    }
}

// 옛 이름(JTM 0.1.x)의 훅이 든 실제 설정 파일을 임시 폴더에서 이전한다.
@Suite struct HookLegacyMigrationFileTests {
    private func legacyFile(_ base: String, agent: HookAgent) throws -> String {
        var config = try HookConfig.parse(Data(base.utf8))
        try config.install(agent: agent, wwiPath: "/Users/me/.local/bin/jtm")
        return config.render().replacingOccurrences(of: "# wwi-managed", with: "# jtm-managed")
    }

    @Test func installMigratesLegacyEntriesWithABackupOfTheOldFile() throws {
        try withTempDir { dir in
            let path = dir + "/settings.json"
            let legacy = try legacyFile(HooksFixtures.claudeSettings, agent: .claude)
            try write(legacy, to: path)

            var plan = try HookInstaller.plan(.install, agent: .claude, path: path, wwiPath: wwiPath)
            #expect(!plan.isNoop)
            try HookInstaller.apply(&plan)

            let result = try read(path)
            #expect(!result.contains("jtm-managed"))
            #expect(result.components(separatedBy: "# wwi-managed").count - 1 == HookAgent.claude.events.count)  // 이벤트마다 정확히 하나
            let saved = try backups(in: dir)
            #expect(saved.count == 1)
            #expect(try read(dir + "/" + saved[0]) == legacy)

            // 이전이 끝나면 다시 실행해도 아무것도 바꾸지 않는다.
            let again = try HookInstaller.plan(.install, agent: .claude, path: path, wwiPath: wwiPath)
            #expect(again.isNoop)
        }
    }

    @Test func uninstallTakesLegacyEntriesOut() throws {
        try withTempDir { dir in
            let path = dir + "/hooks.json"
            try write(try legacyFile(HooksFixtures.codexHooks, agent: .codex), to: path)
            var plan = try HookInstaller.plan(.uninstall, agent: .codex, path: path, wwiPath: "/")
            #expect(plan.changes.count == HookAgent.codex.events.count)
            try HookInstaller.apply(&plan)
            #expect(!(try read(path)).contains("jtm-managed"))
        }
    }
}
