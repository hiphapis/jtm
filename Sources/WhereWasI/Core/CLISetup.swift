import Foundation
import WWICore

/// `~/.local/bin/wwi` 심볼릭 링크의 상태.
public enum CLILinkState: Equatable, Sendable {
    /// 이 앱 안의 `wwi`를 가리킨다.
    case ok
    case missing
    /// 링크이지만 다른 곳(옛 앱, 개발 빌드, 끊어진 경로)을 가리킨다.
    case otherTarget(String)
    /// 링크가 아닌 일반 파일/폴더가 있다(예전에 복사해 둔 `wwi` 등).
    case notALink
    /// 이 앱 번들에 내장 CLI가 없다(`swift run`으로 띄운 개발용 실행 등): 설치할 수 없다.
    case noHelper
}

/// 에이전트 하나(Claude Code 또는 Codex)의 훅 상태.
public enum AgentHooksState: Equatable, Sendable {
    /// 그 에이전트의 설정 폴더(`~/.claude`, `~/.codex`)가 없다: 건드리지 않는다.
    case notPresent
    case installed
    /// 이벤트가 하나라도 없거나 wwi 경로가 다르다.
    case needsInstall
    /// 0.1.x(앱 이름 JTM)가 넣은 `# jtm-managed` 훅이 남아 있다: 설치하면 새 항목으로 바뀐다.
    case needsMigration
    /// 설정 파일을 읽을 수 없다(JSON이 깨졌다 등). 설치는 아무것도 쓰지 않고 이유를 알린다.
    case unreadable(String)

    var needsAttention: Bool {
        switch self {
        case .needsInstall, .needsMigration, .unreadable: true
        case .notPresent, .installed: false
        }
    }
}

public struct SetupStatus: Equatable, Sendable {
    public var link: CLILinkState
    public var claude: AgentHooksState
    public var codex: AgentHooksState
    /// 옛 이름의 `~/.local/bin/jtm` 링크(앱 번들 안 `Contents/Helpers/jtm`을 가리킴)가 남아 있다: 설치하면 지운다.
    public var legacyLink: Bool

    public init(link: CLILinkState, claude: AgentHooksState, codex: AgentHooksState, legacyLink: Bool = false) {
        self.link = link
        self.claude = claude
        self.codex = codex
        self.legacyLink = legacyLink
    }

    public var canInstall: Bool { link != .noHelper }

    /// 첫 실행 카드를 띄울 이유가 있는가: CLI 링크가 없거나 낡았거나, 있는 에이전트의 훅이 빠져 있다.
    public var needsSetup: Bool {
        canInstall && (link != .ok || claude.needsAttention || codex.needsAttention)
    }

    public var hooksInstalledEverywhere: Bool { !claude.needsAttention && !codex.needsAttention }
}

/// 설치·제거 결과. `lines`는 사용자에게 그대로 보여 주는 한 줄씩의 설명이다.
public struct SetupResult: Equatable, Sendable {
    public var lines: [String] = []
    public var error: String?
    /// 이번에 Codex 훅 파일을 실제로 썼다(그러면 Codex 신뢰 안내를 보여 준다).
    public var wroteCodexHooks = false

    public var ok: Bool { error == nil }
}

/// 첫 실행 설정: 앱에 내장된 CLI를 `~/.local/bin/wwi`에 연결하고, Claude Code/Codex 훅을 설치·제거한다.
/// `home`을 주입받아서 테스트는 임시 폴더에서 돌린다(진짜 `~/.claude`, `~/.codex`는 건드리지 않는다).
/// 훅이 부르는 경로는 늘 `~/.local/bin/wwi`이다: 앱을 업데이트해서 번들 안 경로가 바뀌어도 링크만 다시 걸면 된다.
public struct CLISetup: Sendable {
    public let home: String
    /// `<앱>/Contents/Helpers/wwi`. 번들이 아니거나 파일이 없으면 nil.
    public let helperPath: String?

    public init(home: String, helperPath: String?) {
        self.home = home
        self.helperPath = helperPath
    }

    /// 실행 중인 앱 번들 기준. `.app`이 아니거나 `Contents/Helpers/wwi`가 없으면 설치 불가로 본다.
    public static func forBundle(_ bundleURL: URL = Bundle.main.bundleURL, home: String = NSHomeDirectory()) -> CLISetup {
        let helper = bundleURL.appendingPathComponent("Contents/Helpers/wwi").path
        let usable = bundleURL.pathExtension == "app" && FileManager.default.isExecutableFile(atPath: helper)
        return CLISetup(home: home, helperPath: usable ? helper : nil)
    }

    public var linkDirectory: String { home + "/.local/bin" }
    /// 훅 명령에 적히는 wwi 경로(절대 경로여야 한다).
    public var linkPath: String { linkDirectory + "/wwi" }
    /// 0.1.x(앱 이름 JTM)의 CLI 링크 경로.
    public var legacyLinkPath: String { linkDirectory + "/jtm" }

    private var fileManager: FileManager { .default }

    // MARK: Status (read-only)

    public func status() -> SetupStatus {
        SetupStatus(link: linkState(), claude: hooksState(.claude), codex: hooksState(.codex), legacyLink: hasLegacyLink())
    }

    /// `~/.local/bin/jtm`이 앱 번들 안 `Contents/Helpers/jtm`을 가리키는 링크인가(JTM 0.1.x가 만든 것). 직접 만든 `jtm`은 우리 것이 아니다.
    /// 설치 스크립트가 훅 이전에 실패해서 옛 훅을 살려 두려고 `Contents/Helpers/wwi`로 돌려 놓은 링크도 같은 취급이다.
    func hasLegacyLink() -> Bool {
        guard (try? fileManager.attributesOfItem(atPath: legacyLinkPath))?[.type] as? FileAttributeType == .typeSymbolicLink,
              let raw = try? fileManager.destinationOfSymbolicLink(atPath: legacyLinkPath) else { return false }
        return raw.hasSuffix(".app/Contents/Helpers/jtm") || raw.hasSuffix(".app/Contents/Helpers/wwi")
    }

    func linkState() -> CLILinkState {
        guard let helperPath else { return .noHelper }
        guard let type = (try? fileManager.attributesOfItem(atPath: linkPath))?[.type] as? FileAttributeType else { return .missing }
        guard type == .typeSymbolicLink else { return .notALink }
        guard let raw = try? fileManager.destinationOfSymbolicLink(atPath: linkPath) else { return .missing }
        let absolute = raw.hasPrefix("/") ? raw : linkDirectory + "/" + raw
        if Self.realPath(absolute) == Self.realPath(helperPath) { return .ok }
        return .otherTarget(raw)
    }

    func present(_ agent: HookAgent) -> Bool {
        fileManager.fileExists(atPath: home + "/." + agent.rawValue)
            || fileManager.fileExists(atPath: HookInstaller.resolveSymlinks(agent.defaultPath(home: home)))
    }

    func hooksState(_ agent: HookAgent) -> AgentHooksState {
        guard present(agent) else { return .notPresent }
        let resolved = HookInstaller.resolveSymlinks(agent.defaultPath(home: home))
        var config = HookConfig()
        if fileManager.fileExists(atPath: resolved) {
            do { config = try HookConfig.parse(try Data(contentsOf: URL(fileURLWithPath: resolved))) } catch {
                return .unreadable("\(display(agent.defaultPath(home: home))): \(error)")
            }
        }
        do {
            let events = try config.status(agent: agent, wwiPath: linkPath)
            if events.contains(where: { $0.state == .legacy }) { return .needsMigration }
            return events.allSatisfy { $0.state == .installed } ? .installed : .needsInstall
        } catch {
            return .unreadable("\(display(agent.defaultPath(home: home))): \(error)")
        }
    }

    // MARK: Install

    /// 링크를 걸고(필요하면 `~/.local/bin`을 만든다) 있는 에이전트의 훅을 설치한다. 여러 번 실행해도 결과가 같다.
    /// 훅 파일을 모두 읽어 계획을 세운 다음에야 쓴다: 한쪽 설정이 깨져 있으면 링크도 훅도 건드리지 않는다.
    public func install(now: Date = Date()) -> SetupResult {
        var result = SetupResult()
        guard let helperPath else {
            result.error = L10n.string(.setupNoHelper)
            return result
        }

        var plans: [HookFilePlan] = []
        for agent in HookAgent.allCases where present(agent) {
            do {
                plans.append(try HookInstaller.plan(.install, agent: agent, path: agent.defaultPath(home: home), wwiPath: linkPath))
            } catch {
                result.error = "\(error)"
                return result
            }
        }

        do {
            try installLink(to: helperPath, now: now, into: &result)
        } catch {
            result.error = "\(display(linkPath)): \(error.localizedDescription)"
            return result
        }

        if plans.isEmpty {
            result.lines.append(L10n.string(.setupNoAgentFolders))
        }
        for index in plans.indices {
            var plan = plans[index]
            let name = Self.agentName(plan.agent)
            if plan.isNoop {
                result.lines.append(L10n.string(.setupResultAlready, name))
                continue
            }
            do {
                try HookInstaller.apply(&plan, now: now)
            } catch {
                result.error = "\(error)"
                return result
            }
            var line = L10n.string(.setupResultInstalled, name, display(plan.path))
            if let backup = plan.backupPath { line += L10n.string(.setupResultBackup, display(backup)) }
            result.lines.append(line)
            if plan.agent == .codex, plan.written { result.wroteCodexHooks = true }
        }
        // 훅을 모두 새 항목으로 바꾼 뒤에야 옛 링크를 지운다: 도중에 실패하면(위의 `return`) 옛 훅이 아직 이 링크를 부른다.
        removeLegacyLink(into: &result)
        return result
    }

    private func installLink(to helperPath: String, now: Date, into result: inout SetupResult) throws {
        let state = linkState()
        if state == .ok {
            result.lines.append(L10n.string(.setupResultLinkAlready, display(linkPath)))
            return
        }
        try fileManager.createDirectory(atPath: linkDirectory, withIntermediateDirectories: true)
        if state == .notALink {
            // 예전에 복사해 둔 wwi 같은 파일은 지우지 않고 옆으로 치운다.
            let backup = HookInstaller.uniqueBackupPath(for: linkPath, now: now)
            try fileManager.moveItem(atPath: linkPath, toPath: backup)
            result.lines.append(L10n.string(.setupResultMoved, display(linkPath), display(backup)))
        }
        // 임시 링크를 만든 뒤 rename으로 바꿔 끼운다(중간에 링크가 없는 순간이 없다).
        let temp = linkDirectory + "/.wwi.link-\(UUID().uuidString)"
        try fileManager.createSymbolicLink(atPath: temp, withDestinationPath: helperPath)
        guard rename(temp, linkPath) == 0 else {
            let message = String(cString: strerror(errno))
            try? fileManager.removeItem(atPath: temp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message])
        }
        result.lines.append(L10n.string(.setupResultLinked, display(linkPath)))
    }

    /// 옛 이름의 `~/.local/bin/jtm` 링크를 지운다(앱 번들 안 CLI를 가리키는 링크만). 새 훅이 쓰는 경로는 `wwi`라서 더는 필요 없다.
    private func removeLegacyLink(into result: inout SetupResult) {
        guard hasLegacyLink() else { return }
        do {
            try fileManager.removeItem(atPath: legacyLinkPath)
            result.lines.append(L10n.string(.setupResultLegacyLinkRemoved, display(legacyLinkPath)))
        } catch {
            // 못 지워도 설치는 계속한다: 새 링크와 훅은 이 링크 없이 동작한다.
        }
    }

    // MARK: Uninstall hooks

    /// Claude Code/Codex 설정에서 wwi가 넣은 훅만 뺀다(백업을 남긴다). 링크와 앱은 그대로 둔다.
    public func uninstallHooks(now: Date = Date()) -> SetupResult {
        var result = SetupResult()
        var plans: [HookFilePlan] = []
        for agent in HookAgent.allCases {
            do {
                plans.append(try HookInstaller.plan(.uninstall, agent: agent, path: agent.defaultPath(home: home), wwiPath: "/"))
            } catch {
                result.error = "\(error)"
                return result
            }
        }
        for index in plans.indices {
            var plan = plans[index]
            let name = Self.agentName(plan.agent)
            if plan.isNoop {
                result.lines.append(L10n.string(.setupResultNothingToRemove, name))
                continue
            }
            do {
                try HookInstaller.apply(&plan, now: now)
            } catch {
                result.error = "\(error)"
                return result
            }
            var line = L10n.string(.setupResultRemoved, name, display(plan.path))
            if let backup = plan.backupPath { line += L10n.string(.setupResultBackup, display(backup)) }
            result.lines.append(line)
        }
        return result
    }

    // MARK: Helpers

    public static func agentName(_ agent: HookAgent) -> String {
        switch agent {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// 화면에 보일 때는 홈 폴더를 `~`로 줄인다.
    public func display(_ path: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
