import Foundation

public enum SyncError: Error, CustomStringConvertible {
    case orcaNotFound
    case commandFailed(command: String, detail: String)
    case badResponse(command: String, detail: String)

    public var description: String {
        switch self {
        case .orcaNotFound:
            "Orca CLI not found (set ORCA_CLI_COMMAND, or put `orca` on PATH or at \(OrcaCLI.fallbackPath))"
        case .commandFailed(let command, let detail): "`\(command)` failed: \(detail)"
        case .badResponse(let command, let detail): "`\(command)` returned an unexpected response: \(detail)"
        }
    }
}

/// `orca worktree ps --json`와 `orca terminal list --json`의 한 시점 스냅샷. 읽기 전용 명령만 쓴다.
/// 디코딩은 관대하다: 모르는 필드는 무시하고, 선택 필드가 없거나 원소 하나가 깨져 있어도 나머지는 살린다.
public struct OrcaSnapshot: Equatable, Sendable {
    /// `worktrees[].agents[]`의 한 항목(+ 그 워크트리 정보).
    public struct Agent: Equatable, Sendable {
        public var paneKey: String
        public var state: String?
        public var agentType: String?
        public var prompt: String?
        public var updatedAt: Date?
        public var worktreeId: String?
        public var worktreePath: String?

        /// `paneKey` = `<tabId>:<leafId>`. 탭 ID는 UUID라 첫 `:` 앞이 탭이다.
        public var tabId: String { paneKey.split(separator: ":", maxSplits: 1).first.map(String.init) ?? paneKey }
        public var leafId: String? {
            let parts = paneKey.split(separator: ":", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]) : nil
        }

        public init(
            paneKey: String, state: String? = nil, agentType: String? = nil, prompt: String? = nil,
            updatedAt: Date? = nil, worktreeId: String? = nil, worktreePath: String? = nil
        ) {
            self.paneKey = paneKey
            self.state = state
            self.agentType = agentType
            self.prompt = prompt
            self.updatedAt = updatedAt
            self.worktreeId = worktreeId
            self.worktreePath = worktreePath
        }
    }

    public struct Terminal: Equatable, Sendable {
        public var handle: String
        public var ptyId: String?
        public var tabId: String?
        public var leafId: String?
        public var title: String?
        public var orphaned: Bool
        public var worktreeId: String?
        public var worktreePath: String?

        public init(
            handle: String, ptyId: String? = nil, tabId: String? = nil, leafId: String? = nil, title: String? = nil,
            orphaned: Bool = false, worktreeId: String? = nil, worktreePath: String? = nil
        ) {
            self.handle = handle
            self.ptyId = ptyId
            self.tabId = tabId
            self.leafId = leafId
            self.title = title
            self.orphaned = orphaned
            self.worktreeId = worktreeId
            self.worktreePath = worktreePath
        }
    }

    public var agents: [Agent]
    public var terminals: [Terminal]
    /// 어느 한쪽이라도 잘렸으면 true. 잘린 스냅샷에는 없는 항목이 있을 수 있어서 "사라짐"을 판단하지 않는다.
    public var truncated: Bool
    /// 디코딩할 수 없어서 조용히 버린 원소(워크트리, 에이전트, 터미널) 수. 스키마가 바뀌면 원소가 통째로 사라진 것처럼 보이므로 센다.
    public var droppedElements: Int

    public init(
        agents: [Agent] = [], terminals: [Terminal] = [], truncated: Bool = false, droppedElements: Int = 0
    ) {
        self.agents = agents
        self.terminals = terminals
        self.truncated = truncated
        self.droppedElements = droppedElements
    }

    /// "이 탭이 없다"를 믿어도 되는 스냅샷인가. 잘렸거나, 원소를 버렸거나, 에이전트도 터미널도 하나도 없으면
    /// (Orca 재시작 직후이거나 응답 형식이 바뀐 경우) 없는 것이 사라진 것을 뜻하지 않는다.
    public var canDetectGone: Bool {
        !truncated && droppedElements == 0 && !(agents.isEmpty && terminals.isEmpty)
    }

    static let rowLimit = "500"
    public static let commandTimeout: TimeInterval = 20

    public static func psArgv(_ orca: String) -> [String] { [orca, "worktree", "ps", "--json", "--limit", rowLimit] }
    public static func terminalListArgv(_ orca: String) -> [String] { [orca, "terminal", "list", "--json", "--limit", rowLimit] }

    /// 두 명령을 차례로 실행한다. 하나라도 실패하면 던진다(호출자는 아무것도 쓰지 않는다). `timeout`은 명령마다 적용된다
    /// (CLI는 기본 20초, 메뉴바 앱은 더 짧게 준다).
    public static func fetch(runner: CommandRunner, orca: String, timeout: TimeInterval = commandTimeout) throws -> OrcaSnapshot {
        func output(_ argv: [String]) throws -> Data {
            let command = argv.dropFirst().joined(separator: " ")
            let result = runner.run(argv, stdin: nil, timeout: timeout)
            guard result.succeeded else {
                let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw SyncError.commandFailed(command: "orca \(command)", detail: text.isEmpty ? "exit \(result.exitCode)" : "exit \(result.exitCode): \(text)")
            }
            return Data(result.stdout.utf8)
        }
        return try decode(
            worktreePs: try output(psArgv(orca)), terminalList: try output(terminalListArgv(orca)))
    }

    public static func decode(worktreePs: Data, terminalList: Data) throws -> OrcaSnapshot {
        let ps = try decodeEnvelope(PSResult.self, worktreePs, command: "orca worktree ps")
        let list = try decodeEnvelope(ListResult.self, terminalList, command: "orca terminal list")
        let agents = ps.worktrees.compactMap(\.value).flatMap { worktree in
            worktree.agents.compactMap(\.value).map { raw in
                Agent(
                    paneKey: raw.paneKey, state: raw.state, agentType: raw.agentType, prompt: raw.prompt,
                    updatedAt: raw.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                    worktreeId: worktree.worktreeId, worktreePath: worktree.path)
            }
        }
        let terminals = list.terminals.compactMap(\.value).map {
            Terminal(
                handle: $0.handle, ptyId: $0.ptyId, tabId: $0.tabId, leafId: $0.leafId, title: $0.title,
                orphaned: $0.orphaned ?? false, worktreeId: $0.worktreeId, worktreePath: $0.worktreePath)
        }
        let dropped = ps.worktrees.filter { $0.value == nil }.count
            + ps.worktrees.compactMap(\.value).reduce(0) { $0 + $1.droppedAgents }
            + list.terminals.filter { $0.value == nil }.count
        return OrcaSnapshot(
            agents: agents, terminals: terminals, truncated: (ps.truncated ?? false) || (list.truncated ?? false),
            droppedElements: dropped)
    }

    // MARK: Wire format (필요한 필드만, 나머지는 무시)

    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    private struct Envelope<Result: Decodable>: Decodable {
        struct Failure: Decodable { var code: String?; var message: String? }
        var ok: Bool?
        var result: Result?
        var error: Failure?
    }

    private struct PSResult: Decodable {
        var worktrees: [Lossy<RawWorktree>]
        var truncated: Bool?
    }

    private struct RawWorktree: Decodable {
        var worktreeId: String?
        var path: String?
        var agents: [Lossy<RawAgent>]
        /// 못 읽은 에이전트 원소 수(`agents` 자체가 배열이 아니면 1).
        var droppedAgents: Int

        private enum CodingKeys: String, CodingKey { case worktreeId, path, agents }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            worktreeId = try? c.decodeIfPresent(String.self, forKey: .worktreeId)
            path = try? c.decodeIfPresent(String.self, forKey: .path)
            if !c.contains(.agents) || ((try? c.decodeNil(forKey: .agents)) ?? false) {
                agents = []
                droppedAgents = 0
            } else if let list = try? c.decode([Lossy<RawAgent>].self, forKey: .agents) {
                agents = list
                droppedAgents = list.filter { $0.value == nil }.count
            } else {
                agents = []
                droppedAgents = 1
            }
        }
    }

    private struct RawAgent: Decodable {
        var paneKey: String
        var state: String?
        var agentType: String?
        var prompt: String?
        var updatedAt: Double?

        private enum CodingKeys: String, CodingKey { case paneKey, state, agentType, prompt, updatedAt }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            paneKey = try c.decode(String.self, forKey: .paneKey)
            guard !paneKey.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .paneKey, in: c, debugDescription: "empty") }
            state = try? c.decodeIfPresent(String.self, forKey: .state)
            agentType = try? c.decodeIfPresent(String.self, forKey: .agentType)
            prompt = try? c.decodeIfPresent(String.self, forKey: .prompt)
            updatedAt = try? c.decodeIfPresent(Double.self, forKey: .updatedAt)
        }
    }

    private struct ListResult: Decodable {
        var terminals: [Lossy<RawTerminal>]
        var truncated: Bool?
    }

    private struct RawTerminal: Decodable {
        var handle: String
        var ptyId: String?
        var tabId: String?
        var leafId: String?
        var title: String?
        var orphaned: Bool?
        var worktreeId: String?
        var worktreePath: String?

        private enum CodingKeys: String, CodingKey {
            case handle, ptyId, tabId, leafId, title, orphaned, worktreeId, worktreePath
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            handle = try c.decode(String.self, forKey: .handle)
            ptyId = try? c.decodeIfPresent(String.self, forKey: .ptyId)
            tabId = try? c.decodeIfPresent(String.self, forKey: .tabId)
            leafId = try? c.decodeIfPresent(String.self, forKey: .leafId)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            orphaned = try? c.decodeIfPresent(Bool.self, forKey: .orphaned)
            worktreeId = try? c.decodeIfPresent(String.self, forKey: .worktreeId)
            worktreePath = try? c.decodeIfPresent(String.self, forKey: .worktreePath)
        }
    }

    private static func decodeEnvelope<Result: Decodable>(_ type: Result.Type, _ data: Data, command: String) throws -> Result {
        let envelope: Envelope<Result>
        do { envelope = try JSONDecoder().decode(Envelope<Result>.self, from: data) } catch {
            throw SyncError.badResponse(command: command, detail: "not the expected JSON (\(error.localizedDescription))")
        }
        if envelope.ok == false {
            let failure = envelope.error.map { $0.message ?? $0.code ?? "error" } ?? "ok=false"
            throw SyncError.commandFailed(command: command, detail: failure)
        }
        guard let result = envelope.result else { throw SyncError.badResponse(command: command, detail: "no result") }
        return result
    }
}
