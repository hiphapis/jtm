import Foundation
import Testing
@testable import WWICore

// `wwi hooks …`를 실제 바이너리로 돌린다. 안전 규칙: 항상 두 경로를 모두 임시 파일로 지정한다
// (한쪽만 주면 나머지는 실제 ~/.claude, ~/.codex가 대상이 된다).

private let fakeWWI = "/opt/wwi/bin/wwi"

private struct Sandbox {
    var dir: String
    var claude: String { dir + "/claude/settings.json" }
    var codex: String { dir + "/codex/hooks.json" }

    var pathFlags: [String] { ["--claude-settings", claude, "--codex-hooks", codex] }

    func run(_ arguments: [String], extra: [String] = []) -> CLIResult {
        wwi(["hooks"] + arguments + pathFlags + extra, db: dir + "/unused.sqlite")
    }

    func seed() throws {
        for (path, text) in [(claude, HooksFixtures.claudeSettings), (codex, HooksFixtures.codexHooks)] {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    func read(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func backupCount() -> Int {
        let names = FileManager.default.enumerator(atPath: dir)?.allObjects as? [String] ?? []
        return names.filter { $0.contains(".wwi-backup-") }.count
    }
}

private func withSandbox<T>(_ body: (Sandbox) throws -> T) throws -> T {
    let directory = NSTemporaryDirectory() + "wwi-hooks-cli-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    return try body(Sandbox(dir: directory))
}

@Suite struct HooksCLITests {
    @Test func installStatusInstallUninstallRoundTrip() throws {
        try withSandbox { box in
            try box.seed()

            let first = box.run(["install"], extra: ["--wwi-path", fakeWWI])
            #expect(first.status == 0, "\(first.stderr)")
            #expect(first.stdout.contains("+ SessionEnd: 추가"))
            #expect(first.stdout.contains("Codex 안내"), "Codex를 설치하면 신뢰 확인 안내가 나와야 한다")
            #expect(first.stdout.contains("Trust all"))
            #expect(box.backupCount() == 2)

            let status = box.run(["status", "--json"], extra: ["--wwi-path", fakeWWI])
            #expect(status.status == 0)
            let files = try #require(status.object?["files"] as? [[String: Any]])
            #expect(files.map { $0["agent"] as? String } == ["claude", "codex"])
            for file in files {
                let events = try #require(file["events"] as? [[String: Any]])
                #expect(events.allSatisfy { $0["state"] as? String == "installed" })
            }
            #expect((files[0]["events"] as? [[String: Any]])?.count == HookAgent.claude.events.count)
            #expect((files[1]["events"] as? [[String: Any]])?.count == HookAgent.codex.events.count)

            let claudeAfterInstall = box.read(box.claude)
            let again = box.run(["install"], extra: ["--wwi-path", fakeWWI])
            #expect(again.status == 0)
            #expect(again.stdout.contains("변경 없음"))
            #expect(!again.stdout.contains("Codex 안내"), "바뀐 게 없으면 안내를 다시 띄우지 않는다")
            #expect(box.read(box.claude) == claudeAfterInstall)
            #expect(box.backupCount() == 2)

            let stale = box.run(["status", "--json"], extra: ["--wwi-path", "/moved/wwi"])
            let staleFiles = try #require(stale.object?["files"] as? [[String: Any]])
            let staleEvents = try #require(staleFiles[0]["events"] as? [[String: Any]])
            #expect(staleEvents.allSatisfy { $0["state"] as? String == "stale-path" && $0["installedPath"] as? String == fakeWWI })

            let removed = box.run(["uninstall"])
            #expect(removed.status == 0, "\(removed.stderr)")
            #expect(box.read(box.claude) == HooksFixtures.claudeSettings)
            #expect(box.read(box.codex) == HooksFixtures.codexHooks)
            #expect(box.backupCount() == 4)
        }
    }

    @Test func dryRunPrintsDiffAndWritesNothing() throws {
        try withSandbox { box in
            try box.seed()
            let result = box.run(["install"], extra: ["--wwi-path", fakeWWI, "--dry-run"])
            #expect(result.status == 0, "\(result.stderr)")
            #expect(result.stdout.contains("@@"))
            #expect(result.stdout.contains("+            \"command\": \"'\(fakeWWI)' ingest claude # wwi-managed\","))
            #expect(result.stdout.contains("dry-run"))
            #expect(!result.stdout.contains("Codex 안내"))
            #expect(box.read(box.claude) == HooksFixtures.claudeSettings)
            #expect(box.read(box.codex) == HooksFixtures.codexHooks)
            #expect(box.backupCount() == 0)
        }
    }

    @Test func dryRunDoesNotCreateMissingFiles() throws {
        try withSandbox { box in
            let result = box.run(["install"], extra: ["--wwi-path", fakeWWI, "--dry-run"])
            #expect(result.status == 0)
            #expect(box.read(box.claude) == nil)
            #expect(box.read(box.codex) == nil)
            #expect(!FileManager.default.fileExists(atPath: box.dir + "/claude"))
        }
    }

    @Test func onlyLimitsWhichFileIsTouched() throws {
        try withSandbox { box in
            try box.seed()
            let result = box.run(["install"], extra: ["--wwi-path", fakeWWI, "--only", "claude"])
            #expect(result.status == 0, "\(result.stderr)")
            #expect(box.read(box.claude) != HooksFixtures.claudeSettings)
            #expect(box.read(box.codex) == HooksFixtures.codexHooks)
            #expect(!result.stdout.contains("Codex 안내"))
        }
    }

    @Test func installCreatesMissingFilesAndSaysSo() throws {
        try withSandbox { box in
            let result = box.run(["install"], extra: ["--wwi-path", fakeWWI])
            #expect(result.status == 0, "\(result.stderr)")
            #expect(result.stdout.contains("새 파일을 만들었다"))
            #expect(box.read(box.claude)?.contains("ingest claude # wwi-managed") == true)
            #expect(box.read(box.codex)?.contains("ingest codex # wwi-managed") == true)
        }
    }

    @Test func aBrokenFileAbortsBeforeAnyFileIsWritten() throws {
        try withSandbox { box in
            try box.seed()
            try Data("{ not json".utf8).write(to: URL(fileURLWithPath: box.codex))
            let result = box.run(["install"], extra: ["--wwi-path", fakeWWI])
            #expect(result.status != 0)
            #expect(result.stderr.contains("hooks.json"))
            #expect(box.read(box.claude) == HooksFixtures.claudeSettings, "정상 파일도 건드리지 않는다")
            #expect(box.read(box.codex) == "{ not json")
            #expect(box.backupCount() == 0)
        }
    }

    /// N11: 빌드 산출물(.build) 경로를 훅에 넣으려 하면 경고한다(설치는 그대로 진행).
    @Test func installWarnsAboutBuildProductPaths() throws {
        try withSandbox { box in
            let build = box.dir + "/repo/.build/debug/wwi"
            try FileManager.default.createDirectory(atPath: (build as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: build, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
            let built = box.run(["install"], extra: ["--wwi-path", build])
            #expect(built.status == 0)
            #expect(built.stderr.contains(".build") && built.stderr.contains("exit 127"), "\(built.stderr)")

            let normal = Sandbox(dir: box.dir + "/other")
            let installed = normal.run(["install"], extra: ["--wwi-path", box.dir + "/repo/bin/wwi"])
            #expect(!installed.stderr.contains(".build"))
        }
    }

    /// N11: status는 설치된 명령이 가리키는 wwi 파일이 없거나 실행할 수 없으면 알려 준다.
    @Test func statusReportsMissingAndNonExecutableWWIPaths() throws {
        try withSandbox { box in
            let good = box.dir + "/bin/wwi"
            try FileManager.default.createDirectory(atPath: box.dir + "/bin", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: good, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
            #expect(box.run(["install"], extra: ["--wwi-path", good]).status == 0)

            func problems(_ json: CLIResult) -> [String?] {
                let files = json.object?["files"] as? [[String: Any]] ?? []
                return files.flatMap { ($0["events"] as? [[String: Any]] ?? []).map { $0["pathProblem"] as? String } }
            }
            let healthy = box.run(["status", "--json"], extra: ["--wwi-path", good])
            #expect(healthy.status == 0 && problems(healthy).allSatisfy { $0 == nil })

            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: good)
            let notExecutable = box.run(["status", "--json"], extra: ["--wwi-path", good])
            #expect(problems(notExecutable).count == HookAgent.claude.events.count + HookAgent.codex.events.count)
            #expect(problems(notExecutable).allSatisfy { $0 == "not-executable" })
            let text = box.run(["status"], extra: ["--wwi-path", good])
            #expect(text.stdout.contains("wwi를 실행할 수 없다") && text.stdout.contains(good))

            try FileManager.default.removeItem(atPath: good)
            let missing = box.run(["status", "--json"], extra: ["--wwi-path", good])
            #expect(problems(missing).allSatisfy { $0 == "not-found" })
            #expect(box.run(["status"], extra: ["--wwi-path", good]).stdout.contains("wwi 파일이 없다"))
        }
    }

    @Test func relativeWWIPathIsRejected() throws {
        try withSandbox { box in
            let result = box.run(["install"], extra: ["--wwi-path", "wwi"])
            #expect(result.status != 0)
            #expect(box.read(box.claude) == nil)
        }
    }

    @Test func statusOnMissingFilesReportsMissingEvents() throws {
        try withSandbox { box in
            let result = box.run(["status", "--json"], extra: ["--wwi-path", fakeWWI])
            #expect(result.status == 0)
            let files = try #require(result.object?["files"] as? [[String: Any]])
            #expect(files.allSatisfy { $0["exists"] as? Bool == false })
            #expect(files.allSatisfy { ($0["events"] as? [[String: Any]])?.allSatisfy { $0["state"] as? String == "missing" } == true })
        }
    }
}

// 기본 wwi 경로: `~/.local/bin/wwi`가 실행 중인 wwi를 가리키는 링크면 훅이 그 링크를 부른다(설치 스크립트·앱과 같은 경로).
@Suite struct HooksDefaultPathTests {
    private func statusPath(running executable: String, home: String, dir: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["hooks", "status", "--json", "--claude-settings", dir + "/c.json", "--codex-hooks", dir + "/x.json"]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": home]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["wwiPath"] as? String)
    }

    @Test func throughTheStableLinkTheHooksUseTheLinkPath() throws {
        let dir = NSTemporaryDirectory() + "wwi-default-path-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let home = dir + "/home"
        try FileManager.default.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        let link = home + "/.local/bin/wwi"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: wwiExecutable())
        #expect(try statusPath(running: link, home: home, dir: dir) == link)

        // 링크가 없는 홈에서 실행하면 예전처럼 실제 경로다.
        let bareHome = dir + "/bare"
        try FileManager.default.createDirectory(atPath: bareHome, withIntermediateDirectories: true)
        let real = try statusPath(running: wwiExecutable(), home: bareHome, dir: dir)
        #expect(real != link && real.hasSuffix("/wwi"))

        // 링크가 다른 wwi를 가리키면 그 링크를 쓰지 않는다.
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/nonexistent/wwi")
        #expect(try statusPath(running: wwiExecutable(), home: home, dir: dir) == real)
    }
}
