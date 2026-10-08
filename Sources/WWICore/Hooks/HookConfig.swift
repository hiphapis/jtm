import Foundation

/// wwi 훅을 설치할 수 있는 에이전트와 그 이벤트 목록. 근거: `docs/01-product/auto-capture.md` "설치 대상 이벤트".
public enum HookAgent: String, CaseIterable, Sendable, Codable {
    case claude
    case codex

    public var events: [String] {
        switch self {
        case .claude: ["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "SessionEnd", "StopFailure", "PostToolUse"]
        case .codex: ["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "PostToolUse"]
        }
    }

    /// 기본 설정 파일 경로(`home`은 테스트용으로 바꿀 수 있다).
    public func defaultPath(home: String = NSHomeDirectory()) -> String {
        switch self {
        case .claude: home + "/.claude/settings.json"
        case .codex: home + "/.codex/hooks.json"
        }
    }
}

public enum HookEventState: String, Sendable, Codable, Equatable {
    case installed
    case missing
    case stalePath = "stale-path"
    /// 0.1.x(앱 이름 JTM)가 넣은 `# jtm-managed` 항목이 남아 있다. `wwi hooks install`이 제자리에서 새 항목으로 바꾼다.
    case legacy
}

/// 설치된 항목이 가리키는 wwi 파일의 문제. 파일 시스템을 봐야 알 수 있어서 `HookConfig.status`(순수 함수)는 채우지 않고
/// 호출자(`wwi hooks status`)가 `HookPathProblem.check`로 채운다. 이 상태로는 훅이 exit 127/126으로 실패한다.
public enum HookPathProblem: String, Sendable, Codable, Equatable {
    case notFound = "not-found"
    case notExecutable = "not-executable"

    public static func check(_ path: String) -> HookPathProblem? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .notFound }
        return !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path) ? nil : .notExecutable
    }

    /// 개발용 빌드 산출물(`swift run wwi hooks install`이 넣는 debug 빌드 경로)은 `swift package clean` 뒤에 사라진다.
    public static func isBuildProductPath(_ path: String) -> Bool { path.contains("/.build/") }
}

public struct HookEventStatus: Sendable, Codable, Equatable {
    public var event: String
    public var state: HookEventState
    /// 설치돼 있는 항목이 가리키는 wwi 경로(없으면 nil). `stale-path`일 때 무엇이 낡았는지 보여 준다.
    public var installedPath: String?
    /// 그 경로가 없거나 실행할 수 없으면 이유(`hooks status`가 채운다).
    public var pathProblem: HookPathProblem?
}

public enum HookChangeKind: String, Sendable, Equatable {
    case add
    case update
    case remove
}

public struct HookChange: Sendable, Equatable {
    public var event: String
    public var kind: HookChangeKind
}

public enum HookConfigError: Error, CustomStringConvertible, Equatable {
    case rootNotObject
    case hooksNotObject
    case eventNotArray(String)
    case invalidWWIPath(String)

    public var description: String {
        switch self {
        case .rootNotObject: "최상위가 JSON 객체가 아니다"
        case .hooksNotObject: "`hooks` 값이 객체가 아니다"
        case .eventNotArray(let event): "`hooks.\(event)` 값이 배열이 아니다"
        case .invalidWWIPath(let path): "--wwi-path는 제어 문자가 없는 절대 경로여야 한다: \(path)"
        }
    }
}

/// 훅 명령 문자열의 형식과 우리 항목을 알아보는 규칙.
public enum HookCommandFormat {
    public static let marker = "# wwi-managed"
    /// 0.1.x(앱 이름 JTM, CLI `jtm`)가 넣은 표식. 알아보기만 한다: `install`은 새 표식으로 바꾸고 `uninstall`은 뺀다.
    public static let legacyMarker = "# jtm-managed"
    public static let timeout = 5

    /// `'<wwi>' ingest <agent> # wwi-managed`
    public static func command(agent: HookAgent, wwiPath: String) -> String {
        "\(shellQuote(wwiPath)) ingest \(agent.rawValue) \(marker)"
    }

    /// 표식(끝의 `# wwi-managed`)과 ` ingest <agent> `가 모두 있고 맨 앞이 절대 경로면 우리 항목이다.
    /// 경로 값은 보지 않는다 — 경로가 바뀐 옛 항목(stale-path)도 알아봐야 갱신·제거할 수 있다.
    /// 옛 이름 항목(`# jtm-managed`, 절대 경로)도 우리 것으로 본다(`isLegacy`).
    public static func isManaged(_ command: String, agent: HookAgent) -> Bool {
        isCurrent(command, agent: agent) || isLegacy(command, agent: agent)
    }

    /// 옛 이름(JTM 0.1.x)이 넣은 항목: 끝의 `# jtm-managed`, ` ingest <agent> `, 맨 앞의 절대 경로.
    /// 경로 이름은 보지 않는다(`--jtm-path /opt/x/jtm-dev` 같은 직접 지정한 경로도 이전한다). 표식이 우리 것이라는 증거다.
    public static func isLegacy(_ command: String, agent: HookAgent) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(legacyMarker), trimmed.contains(" ingest \(agent.rawValue) ") else { return false }
        guard let path = wwiPath(in: trimmed) else { return false }
        return path.hasPrefix("/")
    }

    private static func isCurrent(_ command: String, agent: HookAgent) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(marker), trimmed.contains(" ingest \(agent.rawValue) ") else { return false }
        guard let path = wwiPath(in: trimmed) else { return false }
        return path.hasPrefix("/")
    }

    /// 명령 맨 앞의 셸 토큰(작은따옴표 인용 또는 공백 전까지)을 경로로 읽는다.
    public static func wwiPath(in command: String) -> String? {
        let chars = Array(command.trimmingCharacters(in: .whitespaces))
        var index = 0
        var result = ""
        var sawToken = false
        while index < chars.count {
            let char = chars[index]
            if char == "'" {
                sawToken = true
                index += 1
                while index < chars.count, chars[index] != "'" { result.append(chars[index]); index += 1 }
                guard index < chars.count else { return nil }
                index += 1
            } else if char == "\\", index + 1 < chars.count {
                sawToken = true
                result.append(chars[index + 1])
                index += 2
            } else if char == " " || char == "\t" {
                break
            } else {
                sawToken = true
                result.append(char)
                index += 1
            }
        }
        return sawToken ? result : nil
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func validate(wwiPath: String) throws {
        guard wwiPath.hasPrefix("/"), !wwiPath.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw HookConfigError.invalidWWIPath(wwiPath)
        }
    }
}

/// `~/.claude/settings.json`, `~/.codex/hooks.json`을 일반 JSON으로 다루며 wwi 항목만 더하고 뺀다.
/// 모르는 키, 키 순서, 기존 훅 그룹의 순서와 내용은 그대로 둔다.
public struct HookConfig: Sendable, Equatable {
    public private(set) var document: JSONDocument

    public init(document: JSONDocument = JSONDocument(root: .object([]))) {
        self.document = document
    }

    public static func parse(_ data: Data) throws -> HookConfig {
        let document = try JSONDocument.parse(data)
        guard case .object = document.root else { throw HookConfigError.rootNotObject }
        return HookConfig(document: document)
    }

    public func render() -> String { document.render() }

    // MARK: 조회

    public func status(agent: HookAgent, wwiPath: String) throws -> [HookEventStatus] {
        let hooks = try hooksMembers()
        let expected = HookCommandFormat.command(agent: agent, wwiPath: wwiPath)
        return try agent.events.map { event in
            let groups = try groups(for: event, in: hooks)
            var managed: [String] = []
            for group in groups {
                for hook in innerHooks(of: group) {
                    if let command = hook["command"]?.stringValue, HookCommandFormat.isManaged(command, agent: agent) {
                        managed.append(command)
                    }
                }
            }
            if managed.isEmpty { return HookEventStatus(event: event, state: .missing, installedPath: nil) }
            // 옛 이름 항목이 하나라도 있으면 legacy(새 항목이 같이 있어도 중복이라 install로 정리해야 한다).
            let legacy = managed.first { HookCommandFormat.isLegacy($0, agent: agent) }
            let stale = legacy ?? managed.first { $0 != expected }
            // 새 항목이 둘 이상이어도 한 개로 줄여야 하니 installed로 보지 않는다.
            let duplicated = managed.count > 1
            let state: HookEventState = legacy != nil ? .legacy : (stale != nil || duplicated ? .stalePath : .installed)
            return HookEventStatus(
                event: event,
                state: state,
                installedPath: HookCommandFormat.wwiPath(in: stale ?? managed[0]))
        }
    }

    // MARK: 설치

    /// 이벤트마다 우리 항목이 없으면 매처 그룹을 **끝에 덧붙이고**, 있는데 명령이 다르면 그 문자열만 바꾼다.
    @discardableResult
    public mutating func install(agent: HookAgent, wwiPath: String) throws -> [HookChange] {
        try HookCommandFormat.validate(wwiPath: wwiPath)
        let expected = HookCommandFormat.command(agent: agent, wwiPath: wwiPath)
        var hooks = try hooksMembers()
        var changes: [HookChange] = []

        for event in agent.events {
            var groups = try groups(for: event, in: hooks)
            var found = false
            var updated = false
            var groupIndex = 0
            while groupIndex < groups.count {
                guard var group = groups[groupIndex].objectValue,
                      let innerIndex = group.firstIndex(where: { $0.key.value == "hooks" }),
                      let inner = group[innerIndex].value.arrayValue else {
                    groupIndex += 1
                    continue
                }
                var rebuilt: [JSONValue] = []
                var groupChanged = false
                for item in inner {
                    guard var hook = item.objectValue,
                          let commandIndex = hook.firstIndex(where: { $0.key.value == "command" }),
                          let command = hook[commandIndex].value.stringValue,
                          HookCommandFormat.isManaged(command, agent: agent) else {
                        rebuilt.append(item)
                        continue
                    }
                    if found {
                        // 이벤트마다 우리 항목은 정확히 하나다: 옛 이름 항목과 새 항목이 같이 있던 경우 등의 중복은 뺀다.
                        groupChanged = true
                        updated = true
                        continue
                    }
                    found = true
                    if command != expected {
                        hook[commandIndex].value = .string(expected)
                        groupChanged = true
                        updated = true
                        rebuilt.append(.object(hook))
                    } else {
                        rebuilt.append(item)
                    }
                }
                guard groupChanged else {
                    groupIndex += 1
                    continue
                }
                if rebuilt.isEmpty {
                    groups.remove(at: groupIndex)
                } else {
                    group[innerIndex].value = .array(rebuilt)
                    groups[groupIndex] = .object(group)
                    groupIndex += 1
                }
            }
            if !found {
                groups.append(Self.newGroup(command: expected))
                changes.append(HookChange(event: event, kind: .add))
            } else if updated {
                changes.append(HookChange(event: event, kind: .update))
            } else {
                continue
            }
            if let index = hooks.firstIndex(where: { $0.key.value == event }) {
                hooks[index].value = .array(groups)
            } else {
                hooks.append(JSONMember(event, .array(groups)))
            }
        }

        if !changes.isEmpty { setHooks(hooks) }
        return changes
    }

    // MARK: 제거

    /// wwi 항목만 뺀다. 그 때문에 비게 된 매처 그룹과 이벤트 배열, `hooks` 객체도 함께 정리한다.
    /// 우리가 건드리지 않은(원래 비어 있던) 배열은 그대로 둔다.
    @discardableResult
    public mutating func uninstall(agent: HookAgent) throws -> [HookChange] {
        guard try hooksValue() != nil else { return [] }
        var hooks = try hooksMembers()
        var changes: [HookChange] = []
        var eventIndex = 0

        while eventIndex < hooks.count {
            let event = hooks[eventIndex].key.value
            guard var groups = hooks[eventIndex].value.arrayValue else {
                eventIndex += 1
                continue
            }
            var removedHere = false
            var groupIndex = 0
            while groupIndex < groups.count {
                guard var group = groups[groupIndex].objectValue,
                      let innerIndex = group.firstIndex(where: { $0.key.value == "hooks" }),
                      var inner = group[innerIndex].value.arrayValue else {
                    groupIndex += 1
                    continue
                }
                let before = inner.count
                inner.removeAll { hook in
                    if let command = hook["command"]?.stringValue { return HookCommandFormat.isManaged(command, agent: agent) }
                    return false
                }
                guard inner.count != before else {
                    groupIndex += 1
                    continue
                }
                removedHere = true
                if inner.isEmpty {
                    groups.remove(at: groupIndex)
                } else {
                    group[innerIndex].value = .array(inner)
                    groups[groupIndex] = .object(group)
                    groupIndex += 1
                }
            }
            guard removedHere else {
                eventIndex += 1
                continue
            }
            changes.append(HookChange(event: event, kind: .remove))
            if groups.isEmpty {
                hooks.remove(at: eventIndex)
            } else {
                hooks[eventIndex].value = .array(groups)
                eventIndex += 1
            }
        }

        if !changes.isEmpty { setHooks(hooks) }
        return changes
    }

    // MARK: 내부

    private static func newGroup(command: String) -> JSONValue {
        .object([
            JSONMember("hooks", .array([
                .object([
                    JSONMember("type", .string("command")),
                    JSONMember("command", .string(command)),
                    JSONMember("timeout", .number(String(HookCommandFormat.timeout))),
                ]),
            ])),
        ])
    }

    private func hooksValue() throws -> JSONValue? {
        guard case .object(let root) = document.root else { throw HookConfigError.rootNotObject }
        return root.first { $0.key.value == "hooks" }?.value
    }

    private func hooksMembers() throws -> [JSONMember] {
        guard let value = try hooksValue() else { return [] }
        guard case .object(let members) = value else { throw HookConfigError.hooksNotObject }
        return members
    }

    private func groups(for event: String, in hooks: [JSONMember]) throws -> [JSONValue] {
        guard let value = hooks.first(where: { $0.key.value == event })?.value else { return [] }
        guard case .array(let groups) = value else { throw HookConfigError.eventNotArray(event) }
        return groups
    }

    private func innerHooks(of group: JSONValue) -> [JSONValue] {
        group["hooks"]?.arrayValue ?? []
    }

    /// `hooks`가 비면(우리가 다 뺀 경우) 키째 지운다. 없던 `hooks`는 설치할 때만 파일 끝에 만든다.
    private mutating func setHooks(_ hooks: [JSONMember]) {
        guard case .object(var root) = document.root else { return }
        let index = root.firstIndex { $0.key.value == "hooks" }
        if hooks.isEmpty {
            if let index { root.remove(at: index) }
        } else if let index {
            root[index].value = .object(hooks)
        } else {
            root.append(JSONMember("hooks", .object(hooks)))
        }
        document.root = .object(root)
    }
}
