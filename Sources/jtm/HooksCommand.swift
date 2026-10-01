import ArgumentParser
import Foundation
import JTMCore

extension HookAgent: ExpressibleByArgument {}

struct HooksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hooks",
        abstract: "Claude Code / Codex 전역 설정에 jtm 훅을 설치·제거·점검한다",
        subcommands: [HooksInstall.self, HooksUninstall.self, HooksStatus.self]
    )
}

/// 세 하위 명령이 공유하는 경로 옵션.
struct HookTargetOptions: ParsableArguments {
    @Option(name: .customLong("claude-settings"), help: "Claude Code 설정 파일 (기본: ~/.claude/settings.json)")
    var claudeSettings: String?
    @Option(name: .customLong("codex-hooks"), help: "Codex 훅 파일 (기본: ~/.codex/hooks.json)")
    var codexHooks: String?
    @Option(help: "한쪽 에이전트만 다룬다 (claude|codex)") var only: HookAgent?

    var targets: [(agent: HookAgent, path: String)] {
        HookAgent.allCases.compactMap { agent in
            if let only, only != agent { return nil }
            switch agent {
            case .claude: return (agent, claudeSettings ?? agent.defaultPath())
            case .codex: return (agent, codexHooks ?? agent.defaultPath())
            }
        }
    }
}

/// 실행 중인 `jtm`의 실제 경로(심볼릭 링크를 푼 값).
private func currentExecutablePath() -> String {
    let url = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    if let real = realpath(url.path, nil) {
        defer { free(real) }
        return String(cString: real)
    }
    return url.path
}

/// 훅이 기본으로 부를 jtm 경로. `~/.local/bin/jtm`이 지금 실행 중인 jtm을 가리키는 링크면 그 링크 경로를 쓴다:
/// 앱을 업데이트해서 번들 안 경로가 바뀌어도 훅을 다시 쓸 필요가 없고, 설치 스크립트와 메뉴바 앱이 쓰는 경로와 같다.
/// 아니면 실제 경로.
/// 홈은 `$HOME`이 우선이다(설치 스크립트가 쓰는 값과 같게. `NSHomeDirectory()`는 `$HOME`을 무시한다).
func defaultJTMPath(
    home: String = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory(),
    executable: String = currentExecutablePath()
) -> String {
    let link = home + "/.local/bin/jtm"
    if let linked = realpath(link, nil) {
        defer { free(linked) }
        if String(cString: linked) == executable { return link }
    }
    return executable
}

private func resolvedJTMPath(_ option: String?, warnsAboutBuildProducts: Bool = false) throws -> String {
    let path = option ?? defaultJTMPath()
    guard path.hasPrefix("/") else { throw ValidationError("--jtm-path는 절대 경로여야 한다: \(path)") }
    if !FileManager.default.isExecutableFile(atPath: path) {
        FileHandle.standardError.write(Data("경고: \(path)는 실행 가능한 파일이 아니다. 훅은 이 경로를 그대로 호출한다.\n".utf8))
    }
    if warnsAboutBuildProducts, HookPathProblem.isBuildProductPath(path) {
        FileHandle.standardError.write(Data(
            "경고: \(path)는 빌드 산출물(.build) 경로다. swift package clean이나 다시 빌드하면 사라져서 훅이 exit 127로 실패한다. 설치한 jtm을 --jtm-path로 지정하는 편이 안전하다.\n".utf8))
    }
    return path
}

private func describe(_ change: HookChange) -> String {
    switch change.kind {
    case .add: "  + \(change.event): 추가"
    case .update: "  ~ \(change.event): jtm 경로 갱신"
    case .remove: "  - \(change.event): 제거"
    }
}

/// 파일별 계획을 모두 세운 뒤에 쓴다 — 한쪽 파일이 깨져 있으면 어느 쪽도 건드리지 않는다.
private func runPlans(
    _ operation: HookFilePlan.Operation, targets: [(agent: HookAgent, path: String)],
    jtmPath: String, dryRun: Bool
) throws {
    var plans = try targets.map { try HookInstaller.plan(operation, agent: $0.agent, path: $0.path, jtmPath: jtmPath) }

    for index in plans.indices {
        var plan = plans[index]
        let label = "\(plan.agent.rawValue): \(plan.path)"
        if plan.isNoop {
            let reason = operation == .install ? "이미 설치돼 있음" : "제거할 jtm 항목 없음"
            print("\(label)\n  변경 없음 (\(reason))")
            continue
        }
        print(label)
        plan.changes.forEach { print(describe($0)) }

        if dryRun {
            let diff = TextDiff.unified(
                old: plan.before, new: plan.after,
                oldLabel: plan.existed ? plan.path : "(없음)", newLabel: plan.path + " (dry-run)",
                maxLineLength: 160)
            print(diff, terminator: "")
            print("  dry-run: 파일을 쓰지 않았다")
        } else {
            try HookInstaller.apply(&plan)
            if let backup = plan.backupPath { print("  백업: \(backup)") }
            else if !plan.existed { print("  새 파일을 만들었다 (백업 없음)") }
            print("  저장 완료")
            plans[index] = plan
        }
    }

    if operation == .install, !dryRun, plans.contains(where: { $0.agent == .codex && $0.written }) {
        print("\n" + HookNotices.codexTrust.joined(separator: "\n"))
    }
}

struct HooksInstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "이벤트별 jtm 훅을 추가한다 (기존 훅은 건드리지 않고, 여러 번 실행해도 결과가 같다)")

    @OptionGroup var targetOptions: HookTargetOptions
    @Option(name: .customLong("jtm-path"), help: "훅이 호출할 jtm 절대 경로 (기본: ~/.local/bin/jtm이 실행 중인 jtm을 가리키면 그 링크, 아니면 실제 경로)")
    var jtmPath: String?
    @Flag(name: .customLong("dry-run"), help: "파일을 쓰지 않고 변경 내용만 보여 준다") var dryRun = false

    func run() throws {
        try runPlans(
            .install, targets: targetOptions.targets,
            jtmPath: try resolvedJTMPath(jtmPath, warnsAboutBuildProducts: true), dryRun: dryRun)
    }
}

struct HooksUninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall", abstract: "jtm이 설치한 훅만 제거한다 (백업 후)")

    @OptionGroup var targetOptions: HookTargetOptions
    @Flag(name: .customLong("dry-run"), help: "파일을 쓰지 않고 변경 내용만 보여 준다") var dryRun = false

    func run() throws {
        // 제거는 경로와 무관하게 표식으로 찾으므로 jtm 경로가 필요 없다.
        try runPlans(.uninstall, targets: targetOptions.targets, jtmPath: "/", dryRun: dryRun)
    }
}

struct HooksStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "파일·이벤트별로 installed / missing / stale-path를 보여 준다")

    @OptionGroup var targetOptions: HookTargetOptions
    @Option(name: .customLong("jtm-path"), help: "기준 jtm 절대 경로 (기본: ~/.local/bin/jtm이 실행 중인 jtm을 가리키면 그 링크, 아니면 실제 경로)")
    var jtmPath: String?
    @Flag(help: "JSON으로 출력") var json = false

    private struct FileReport: Encodable {
        var agent: HookAgent
        var path: String
        var exists: Bool
        var events: [HookEventStatus]
    }

    private struct Report: Encodable {
        var jtmPath: String
        var files: [FileReport]
        let ok = true
    }

    func run() throws {
        let jtm = try resolvedJTMPath(jtmPath)
        var files: [FileReport] = []
        for target in targetOptions.targets {
            let path = URL(fileURLWithPath: (target.path as NSString).expandingTildeInPath).standardizedFileURL.path
            let resolved = HookInstaller.resolveSymlinks(path)
            let exists = FileManager.default.fileExists(atPath: resolved)
            var config = HookConfig()
            if exists {
                do { config = try HookConfig.parse(try Data(contentsOf: URL(fileURLWithPath: resolved))) } catch {
                    throw ValidationError("\(path): \(error)")
                }
            }
            do {
                var events = try config.status(agent: target.agent, jtmPath: jtm)
                for index in events.indices {
                    events[index].pathProblem = events[index].installedPath.flatMap(HookPathProblem.check)
                }
                files.append(FileReport(agent: target.agent, path: path, exists: exists, events: events))
            } catch {
                throw ValidationError("\(path): \(error)")
            }
        }

        if json {
            try printJSON(Report(jtmPath: jtm, files: files))
            return
        }
        print("jtm: \(jtm)")
        for file in files {
            print("\n\(file.agent.rawValue): \(file.path)\(file.exists ? "" : " (파일 없음)")")
            for event in file.events {
                var line = "  \(event.event.padding(toLength: 18, withPad: " ", startingAt: 0)) \(event.state.rawValue)"
                if event.state == .stalePath, let old = event.installedPath { line += "  (\(old))" }
                if let problem = event.pathProblem, let path = event.installedPath {
                    line += "  ⚠ \(problem == .notFound ? "jtm 파일이 없다" : "jtm을 실행할 수 없다"): \(path)"
                }
                print(line)
            }
        }
    }
}
