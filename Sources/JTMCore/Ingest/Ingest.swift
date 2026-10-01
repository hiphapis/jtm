import Foundation

/// `jtm ingest`의 본체(입출력 없음): 훅 stdin 바이트 → 이벤트 → Reconciler.
public enum Ingest {
    /// stdin은 이 크기까지만 읽는다. PostToolUse의 `tool_response`나 큰 Write/Edit 입력이 1MiB를 넘을 수 있어서 8MiB다.
    public static let inputLimit = 8 * 1_048_576

    /// 헤드리스/중첩 실행(`claude -p` 등)의 이벤트인지. 그런 자식 프로세스는 부모 터미널의 `ORCA_*`를 물려받아서
    /// 실행마다 티켓을 만들고 탭을 가져가므로 무시한다. Claude는 `CLAUDE_CODE_ENTRYPOINT`가 대화형 TUI에서는 `cli`,
    /// 헤드리스에서는 `sdk-cli` 등이다(실측). 값이 없거나 비어 있으면 대화형으로 본다.
    /// Codex는 페이로드/환경에서 `exec` 표지를 확정하지 못해서(실행해 보지 않고는 알 수 없다) 걸러내지 않는다.
    public static func isNestedSession(agent agentName: String, environment: [String: String]) -> Bool {
        guard agentName == AgentType.claude.rawValue,
              let entrypoint = environment["CLAUDE_CODE_ENTRYPOINT"], !entrypoint.isEmpty
        else { return false }
        return entrypoint != "cli"
    }

    /// 처리 대상이 아닌 이벤트는 조용히 nil을 돌려준다. 그 밖의 문제는 던진다(호출자가 로그에 남긴다).
    @discardableResult
    public static func handle(
        agent agentName: String, input: Data, environment: [String: String],
        store: Store, projectResolver: ProjectResolver, defaultCwd: String? = nil, now: Date = Date()
    ) throws -> Reconciler.Outcome? {
        if isNestedSession(agent: agentName, environment: environment) { return nil }
        guard let event = try parse(agent: agentName, input: input, defaultCwd: defaultCwd) else { return nil }
        return try Reconciler(store: store, projectResolver: projectResolver)
            .apply(event: event, env: OrcaEnv(environment: environment), now: now)
    }

    /// 이벤트에 cwd가 없으면 훅 프로세스의 작업 디렉터리를 쓴다(훅은 세션의 cwd에서 실행된다).
    public static func parse(agent agentName: String, input: Data, defaultCwd: String? = nil) throws -> AgentEvent? {
        guard let agent = AgentType(rawValue: agentName) else { throw IngestError.unknownAgent(agentName) }
        guard !input.isEmpty else { throw IngestError.emptyInput }
        guard input.count <= inputLimit else { throw IngestError.payloadTooLarge(limit: inputLimit) }
        guard var event = try AgentEvent.parse(agent: agent, json: input) else { return nil }
        if event.cwd == nil { event.cwd = defaultCwd }
        return event
    }
}
