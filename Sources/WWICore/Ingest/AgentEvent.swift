import Foundation

public enum AgentType: String, Sendable {
    case claude
    case codex
}

/// 티켓 상태에 영향을 주는 훅 이벤트. 이 밖의 이벤트(`Notification` 등)는 파싱 단계에서 버린다.
/// `StopFailure`(API 오류로 턴이 끝남)는 Claude에만 있다.
public enum AgentEventKind: String, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case stop = "Stop"
    case permissionRequest = "PermissionRequest"
    case sessionEnd = "SessionEnd"
    case stopFailure = "StopFailure"
    case postToolUse = "PostToolUse"
}

public enum IngestError: Error, CustomStringConvertible {
    case missingAgent
    case unknownAgent(String)
    case emptyInput
    case payloadTooLarge(limit: Int)
    case invalidJSON
    case missingSessionId(event: String)

    public var description: String {
        switch self {
        case .missingAgent: "missing agent argument (expected claude|codex)"
        case .unknownAgent(let name): "unknown agent '\(name)' (expected claude|codex)"
        case .emptyInput: "empty stdin"
        case .payloadTooLarge(let limit): "payload larger than \(limit) bytes"
        case .invalidJSON: "stdin is not a JSON object"
        case .missingSessionId(let event): "\(event) payload has no session_id"
        }
    }
}

public struct AgentEvent: Equatable, Sendable {
    public var agent: AgentType
    public var kind: AgentEventKind
    public var sessionId: String
    public var cwd: String?
    public var prompt: String?
    /// Codex가 기록 파일 위치로 보내 주는 `transcript_path`. 내부 작업을 가려내는 데만 쓴다(`CodexSessionMeta`).
    public var transcriptPath: String?

    public init(
        agent: AgentType, kind: AgentEventKind, sessionId: String, cwd: String? = nil, prompt: String? = nil,
        transcriptPath: String? = nil
    ) {
        self.agent = agent
        self.kind = kind
        self.sessionId = sessionId
        self.cwd = cwd
        self.prompt = prompt
        self.transcriptPath = transcriptPath
    }

    /// 훅 stdin JSON을 이벤트로 바꾼다. 처리 대상이 아닌 이벤트(`hook_event_name`이 없거나 모르는 값, `Notification`,
    /// Codex의 `SessionEnd` 등)는 조용히 `nil`이다. 처리 대상인데 `session_id`가 없으면 던진다.
    public static func parse(agent: AgentType, json: Data) throws -> AgentEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw IngestError.invalidJSON
        }
        guard let name = object["hook_event_name"] as? String, let kind = AgentEventKind(rawValue: name) else {
            return nil
        }
        // Codex에는 SessionEnd가 없다. 오더라도 종료 신호는 Orca 폴러가 판단한다.
        if agent == .codex, kind == .sessionEnd || kind == .stopFailure { return nil }
        guard let sessionId = object["session_id"] as? String, !sessionId.isEmpty else {
            throw IngestError.missingSessionId(event: name)
        }
        return AgentEvent(
            agent: agent, kind: kind, sessionId: sessionId,
            cwd: (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            prompt: object["prompt"] as? String,
            transcriptPath: (object["transcript_path"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// Orca 터미널 안에서 도는 에이전트가 물려받는 환경변수.
public struct OrcaEnv: Equatable, Sendable {
    public var terminalHandle: String?
    public var tabId: String?
    public var worktreeId: String?

    public init(terminalHandle: String? = nil, tabId: String? = nil, worktreeId: String? = nil) {
        self.terminalHandle = terminalHandle
        self.tabId = tabId
        self.worktreeId = worktreeId
    }

    /// `ORCA_*`가 하나도 없으면(Orca 밖) nil. 빈 값은 없는 것으로 본다.
    public init?(environment: [String: String]) {
        func value(_ key: String) -> String? { environment[key].flatMap { $0.isEmpty ? nil : $0 } }
        let parsed = OrcaEnv(
            terminalHandle: value("ORCA_TERMINAL_HANDLE"), tabId: value("ORCA_TAB_ID"),
            worktreeId: value("ORCA_WORKTREE_ID"))
        guard parsed.terminalHandle != nil || parsed.tabId != nil || parsed.worktreeId != nil else { return nil }
        self = parsed
    }
}
