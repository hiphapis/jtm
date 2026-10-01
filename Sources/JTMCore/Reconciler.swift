import Foundation

/// 에이전트 훅 이벤트를 티켓/위치에 반영한다(`docs/01-product/auto-capture.md`의 이벤트 표).
/// 저장소 위의 순수 로직이다: 프로세스를 띄우지 않고, 시계는 `now`로 받고, 프로젝트 추정은 주입받는다.
/// 한 이벤트는 한 트랜잭션이다. 스레드 간에 공유하지 않는다(`Store`와 같다).
public struct Reconciler {
    public struct Outcome: Equatable, Sendable {
        public var ticketId: Int64
        public var created: Bool
    }

    /// 제목이 아직 없는 티켓의 자리표시자. 첫 프롬프트가 오면 그 제목으로 바뀐다(고정된 제목은 건드리지 않는다).
    public static func placeholderTitle(for agent: AgentType) -> String { "\(agent.rawValue) session" }

    private static let titleLimit = 60
    /// 폴러가 만든 탭 티켓을 새 세션이 입양할 수 있는 최대 비활동 시간.
    public static let adoptWindow: TimeInterval = 10 * 60
    /// Codex 기록 파일이 처음 "없음"으로 보인 뒤 이 시간이 지나도 계속 없으면 일회성 내부 작업으로 보고 무시한다.
    /// 그 전에는 티켓도 무시 기록도 만들지 않고 다음 이벤트에서 다시 판단한다(사용자 세션은 보통 1~2초 안에 파일이 생긴다).
    public static let missingRolloutGrace: TimeInterval = 20

    private let store: Store
    private let projectResolver: ProjectResolver
    private let transcriptReader: CodexTranscriptReading

    public init(
        store: Store, projectResolver: ProjectResolver,
        transcriptReader: CodexTranscriptReading = FileCodexTranscriptReader()
    ) {
        self.store = store
        self.projectResolver = projectResolver
        self.transcriptReader = transcriptReader
    }

    /// 이벤트를 반영하고 대상 티켓을 돌려준다. 티켓을 만들지 않고 넘어가는 이벤트(모르는 세션의 `SessionEnd`)는 nil.
    @discardableResult
    public func apply(event: AgentEvent, env: OrcaEnv?, now: Date) throws -> Outcome? {
        try store.transaction {
            let key = "\(event.agent.rawValue):\(event.sessionId)"
            // 워커 세션은 모든 이벤트를 버린다: Stop/PermissionRequest도 티켓을 만들 수 있어서 가장 먼저 확인한다.
            if try store.isSessionIgnored(key), try !healsMissingRolloutIgnore(key: key, event: event) { return nil }
            let existing = try store.location(byExternalKey: key)
            if let reason = try workerReason(of: event, env: env) {
                try ignoreWorker(key: key, reason: reason, existing: existing, env: env)
                return nil
            }
            // Codex 내부 작업(하위 에이전트, guardian 검토, 기록 파일 없는 일회성 작업)은 티켓을 만들지 않는다.
            var carriedTitle: String?
            switch try internalVerdict(of: event, existing: existing, key: key, now: now) {
            case .collect:
                // 파일이 없어 보류했던 세션이 사용자 세션으로 판명됐다: 보류 중에 본 첫 프롬프트 제목을 이어받는다.
                if event.agent == .codex, existing == nil, let pending = try store.codexUndecided(key) {
                    carriedTitle = pending.title
                    try store.clearCodexUndecided(key)
                }
            case .undecided: return nil
            case .ignore(let reason):
                try store.ignoreSession(key, reason: reason)
                try store.clearCodexUndecided(key)
                return nil
            }
            // 끝난 세션의 흔적이나 도구 사용만으로 티켓을 새로 만들지는 않는다(PostToolUse는 도구 호출마다 온다).
            if event.kind == .sessionEnd || event.kind == .postToolUse, existing == nil { return nil }

            // resume 명령이 `cd ''`로 망가지지 않게, 이 이벤트에 cwd가 없으면 이미 아는 값을 유지한다.
            let cwd = event.cwd ?? existing.flatMap { Self.cwd(of: $0.locator) }
            let target = Self.target(for: event.kind)
            // Codex 데스크톱 앱의 "참조한 ChatGPT 대화" 머리말은 제목에 쓰지 않고, 그 대화를 같은 티켓의 위치로 붙인다.
            let isPrompt = event.kind == .userPromptSubmit
            let reference = isPrompt ? event.prompt.flatMap(ReferencedConversation.parse) : nil
            let promptTitle = (isPrompt ? event.prompt.flatMap { reference.map(\.title) ?? Self.normalizedTitle($0) } : nil)
                ?? carriedTitle
            let placeholder = Self.placeholderTitle(for: event.agent)

            let locator = Self.sessionLocator(event, cwd: cwd)
            let found: (ticket: Ticket, created: Bool)
            var adopted = false
            if existing == nil, let adopter = try adoptableTicket(env: env, now: now) {
                // 폴러가 탭만 보고 만든 티켓(세션 위치 없음)이 있으면 새로 만들지 않고 세션을 거기에 붙인다.
                try store.addLocation(ticketId: adopter.id, locator: locator, source: .hook, externalKey: key)
                found = (adopter, false)
                adopted = true
            } else {
                let upserted = try store.upsertTicketAndLocation(
                    externalKey: key, locator: locator, source: .hook,
                    newTicket: NewTicket(
                        title: promptTitle ?? placeholder, status: target.status ?? .active,
                        project: projectName(env: env, cwd: cwd), waitingReason: target.reason))
                found = (upserted.ticket, upserted.created)
            }
            let ticket = found.ticket

            if !found.created {
                if ticket.project == nil, let project = projectName(env: env, cwd: cwd) {
                    try store.patchTicket(id: ticket.id, TicketPatch(project: .some(project)))
                }
                if let promptTitle, ticket.title == placeholder {
                    try store.autoUpdateTitle(id: ticket.id, title: promptTitle)
                }
                if ticket.status == .done {
                    // 사용자가 done으로 닫은 티켓은 다시 열지 않는다(활동 시간만 갱신). 시스템이 자동으로 닫은 티켓(`autoDoneAt`)만
                    // 같은 세션이 다시 시작하거나 프롬프트를 받을 때 연다. Stop/PermissionRequest/PostToolUse로는 열지 않는다
                    // (늦게 도착한 옛 이벤트가 끝난 티켓을 되살리면 안 된다).
                    if ticket.autoDoneAt != nil, event.kind == .sessionStart || event.kind == .userPromptSubmit {
                        try store.patchTicket(id: ticket.id, Self.reopenPatch)
                    }
                } else if let patch = Self.statePatch(for: event.kind, of: ticket, now: now) {
                    try store.patchTicket(id: ticket.id, patch)
                }
            }

            // SessionEnd는 위치를 건드리지 않는다. 늦게 도착한 옛 세션의 이벤트가 탭을 되찾아 가면 안 된다.
            if event.kind != .sessionEnd {
                // 탭을 가져가는 것은 세션이 실제로 (다시) 움직였다는 신호뿐이다: SessionStart, UserPromptSubmit, 티켓 생성·입양.
                // 그 밖의 이벤트(Stop, PermissionRequest, StopFailure, PostToolUse)는 주인이 없을 때만 붙는다.
                let takesTab = event.kind == .sessionStart || event.kind == .userPromptSubmit || found.created || adopted
                try attachOrcaTerminal(env: env, to: ticket.id, now: now, takesOwnership: takesTab)
            }
            if let conversationId = reference?.conversationId {
                try Self.attachChatGPTChat(conversationId: conversationId, to: ticket.id, store: store)
            }
            try store.touchActivity(id: ticket.id, at: now)
            return Outcome(ticketId: ticket.id, created: found.created)
        }
    }

    // MARK: Orchestration workers

    /// 워커 세션이면 그 이유. 첫 프롬프트에 워커 안내문이 있거나, 이 터미널이 Orca가 알려 준 워커 터미널이다.
    /// 프로세스를 띄우지 않고 DB 조회만 한다(훅의 시간 예산).
    private func workerReason(of event: AgentEvent, env: OrcaEnv?) throws -> String? {
        if event.kind == .userPromptSubmit, let prompt = event.prompt, OrcaWorker.isWorkerPrompt(prompt) {
            return OrcaWorker.promptReason
        }
        if let handle = env?.terminalHandle, try store.isOrcaWorkerHandle(handle) { return OrcaWorker.handleReason }
        return nil
    }

    /// 세션을 무시 목록에 올리고, 이 세션 때문에 생긴 티켓이 그대로면 지운다. 탭 위치는 가져가지 않는다.
    /// 사용자가 손댄 티켓은 지우지 않는다(세션만 이후 이벤트에서 빠진다).
    private func ignoreWorker(key: String, reason: String, existing: Location?, env: OrcaEnv?) throws {
        try store.ignoreSession(key, reason: reason)
        // 이 터미널은 워커의 것이다: 폴러가 같은 탭으로 티켓을 다시 만들지 않게 handle도 남긴다.
        if let handle = env?.terminalHandle { try store.upsertOrcaWorkerHandle(handle, runId: nil) }
        if let existing {
            try OrcaWorker.removeIfUntouched(ticketId: existing.ticketId, store: store, ownKey: key, reason: reason)
        }
    }

    /// 자동 완료된 티켓을 다시 열 때의 변경: 진행 중으로, 끝난 시각·보관·자동 완료 표지를 지운다.
    static let reopenPatch = TicketPatch(
        status: .active, waitingReason: .some(nil), endedAt: .some(nil), archivedAt: .some(nil), autoDoneAt: .some(nil))

    // MARK: Codex internal sessions

    private enum InternalVerdict { case collect, undecided, ignore(reason: String) }

    /// "파일 없음"으로 무시했던 세션(`codex-internal-nofile`)이 이제 기록 파일이 생겼으면 무시를 풀어 수집한다(자기 치유).
    /// 풀면 true. 파일이 여전히 없거나(계속 무시), 다른 사유로 무시한 세션이면 false. 파일이 생겼는데 내부 작업이면 사유를 확정(`codex-internal`)한다.
    private func healsMissingRolloutIgnore(key: String, event: AgentEvent) throws -> Bool {
        guard event.agent == .codex, let path = event.transcriptPath,
              try store.ignoredSessionReason(key) == CodexSessionMeta.noFileReason
        else { return false }
        switch transcriptReader.probe(path: path) {
        case .missing: return false
        case .meta(let meta) where meta.isInternal:
            try store.unignoreSession(key)
            try store.ignoreSession(key, reason: CodexSessionMeta.internalReason)
            return false
        case .meta, .unknown:
            try store.unignoreSession(key)
            return true
        }
    }

    /// Codex 이벤트가 내부 작업의 것인지(`docs/01-product/auto-capture.md`). 기록 파일의 첫 줄(`session_meta`)로 가른다.
    /// - 이미 티켓이 있는 세션은 처음 이벤트에서 통과한 것이라 다시 읽지 않는다(훅마다 파일을 읽지 않으려고).
    /// - `transcript_path`가 없으면 사용자 세션으로 본다(보수적). 첫 줄을 못 읽어도 마찬가지다.
    /// - 파일이 없으면 어떤 이벤트든 티켓도 무시 기록도 남기지 않고(`undecided`) 다음 이벤트에서 다시 판단한다. 처음 없다고 본 시각을
    ///   적어 두고(`codex-undecided`), `missingRolloutGrace`가 지나도 계속 없을 때만 일회성 내부 작업으로 보고 무시한다
    ///   (`codex-internal-nofile`: 나중에 파일이 생기면 스스로 풀린다). 사용자 세션을 첫 프롬프트에서 영구히 버리지 않는다.
    private func internalVerdict(of event: AgentEvent, existing: Location?, key: String, now: Date) throws -> InternalVerdict {
        guard event.agent == .codex, existing == nil, let path = event.transcriptPath else { return .collect }
        switch transcriptReader.probe(path: path) {
        case .missing:
            let note = try store.noteCodexUndecided(key, title: event.prompt.flatMap(Self.title(fromPrompt:)))
            return now.timeIntervalSince(note.firstSeen) >= Self.missingRolloutGrace
                ? .ignore(reason: CodexSessionMeta.noFileReason) : .undecided
        case .unknown: return .collect
        case .meta(let meta): return meta.isInternal ? .ignore(reason: CodexSessionMeta.internalReason) : .collect
        }
    }

    // MARK: Event table

    /// 새 티켓의 시작 상태. `status`가 nil이면 상태를 바꾸지 않는 이벤트다(`SessionEnd`).
    private static func target(for kind: AgentEventKind) -> (status: TicketStatus?, reason: WaitingReason?) {
        switch kind {
        case .sessionStart, .userPromptSubmit: (.active, nil)
        case .stop: (.waiting, .turnEnd)
        case .permissionRequest: (.waiting, .permission)
        case .stopFailure: (.waiting, .error)
        case .sessionEnd, .postToolUse: (nil, nil)
        }
    }

    /// 이미 있는 (done이 아닌) 티켓에 적용할 변경. 바뀔 게 없으면 nil.
    /// 세션이 다시 활동하면(`SessionStart`/`UserPromptSubmit`) 이전 `ended_at`을 지운다.
    private static func statePatch(for kind: AgentEventKind, of ticket: Ticket, now: Date) -> TicketPatch? {
        let (status, reason) = target(for: kind)
        guard let status else {
            switch kind {
            // 유지(⭐)가 아닌 티켓은 세션이 끝나면 done이 된다(자동 완료: 표지를 남겨 나중에 다시 열 수 있게 한다).
            // 유지 티켓과 blocked(사용자만 정하는 상태)는 끝난 시각만 남긴다.
            case .sessionEnd:
                let protected = ticket.kept || ticket.status == .blocked
                return TicketPatch(status: protected ? nil : .done, endedAt: .some(now), autoDoneAt: protected ? nil : .some(now))
            // 권한 요청을 승인하면 도구가 돌고 PostToolUse가 온다: 그때 다시 active. 그 밖의 대기 상태는 그대로 둔다.
            case .postToolUse:
                return ticket.status == .waiting && ticket.waitingReason == .permission
                    ? TicketPatch(status: .active, waitingReason: .some(nil)) : nil
            default: return nil
            }
        }
        let reviving = kind == .sessionStart || kind == .userPromptSubmit
        guard status != ticket.status || reason != ticket.waitingReason || (reviving && ticket.endedAt != nil) else {
            return nil
        }
        return TicketPatch(
            status: status, waitingReason: .some(reason), endedAt: reviving && ticket.endedAt != nil ? .some(nil) : nil)
    }

    // MARK: Locations

    private static func sessionLocator(_ event: AgentEvent, cwd: String?) -> Locator {
        switch event.agent {
        case .claude: .claudeCode(.init(sessionId: event.sessionId, cwd: cwd ?? ""))
        case .codex: .codexThread(.init(threadId: event.sessionId, cwd: cwd))
        }
    }

    private static func cwd(of locator: Locator) -> String? {
        switch locator {
        case .claudeCode(let session): session.cwd.isEmpty ? nil : session.cwd
        case .codexThread(let thread): thread.cwd
        default: nil
        }
    }

    /// 입양 대상: 이 탭(`orca-tab:<tabId>`)의 위치가 속한 티켓 중 세션 위치(claude_code/codex_thread)가 하나도 없고
    /// done이 아닌 것. 이미 세션이 있는 티켓이면 nil이라 "탭 위치를 새 세션의 티켓으로 옮긴다" 규칙이 적용된다.
    /// 폴러가 만든 티켓(탭 위치의 출처가 `orca_sync`)이면서 최근(`adoptWindow`) 활동이 있는 것만 입양한다:
    /// 사용자가 손댔거나 오래 방치된 티켓이 무관한 새 세션을 흡수하지 않게 한다.
    private func adoptableTicket(env: OrcaEnv?, now: Date) throws -> Ticket? {
        guard let env, env.terminalHandle != nil, let tabId = env.tabId,
              let tab = try store.location(byExternalKey: "orca-tab:\(tabId)"), tab.source == .orcaSync
        else { return nil }
        let ticket = try store.getTicket(id: tab.ticketId)
        guard ticket.status != .done, now.timeIntervalSince(ticket.lastActivityAt) <= Self.adoptWindow else { return nil }
        let hasSession = try store.locations(ticketId: ticket.id).contains {
            $0.kind == .claudeCode || $0.kind == .codexThread
        }
        return hasSession ? nil : ticket
    }

    /// `orca-tab:<tabId>` 위치를 이 티켓에 붙인다. `takesOwnership`이면 이미 다른 티켓에 있어도 옮긴다
    /// (같은 탭, 새 세션 → 최신 세션이 주인). 아니면 위치가 없거나 이미 이 티켓 것일 때만 붙이고, 남의 것이면 건드리지 않는다.
    /// 탭 ID가 없으면 키를 만들 수 없어서 붙이지 않는다.
    private func attachOrcaTerminal(env: OrcaEnv?, to ticketId: Int64, now: Date, takesOwnership: Bool) throws {
        guard let env, let handle = env.terminalHandle, let tabId = env.tabId else { return }
        let key = "orca-tab:\(tabId)"
        let known = try store.location(byExternalKey: key)
        if let known, known.ticketId != ticketId, !takesOwnership { return }
        var terminal = Locator.OrcaTerminal(terminalHandle: handle, worktreeId: env.worktreeId, tabId: tabId)
        if let known, case .orcaTerminal(let old) = known.locator {
            // 폴러가 채운 값(ptyId, 제목)을 훅이 지우지 않는다. ptyId는 같은 터미널일 때만 유효하다.
            if old.terminalHandle == handle { terminal.ptyId = old.ptyId }
            terminal.titleHint = old.titleHint
            terminal.worktreeId = terminal.worktreeId ?? old.worktreeId
        }
        // 사용자가 무시한 티켓의 탭에서 새 세션이 시작됐다: 폴러 쪽 무시 표시는 더는 필요 없다(이 티켓이 탭의 주인이다).
        if takesOwnership { try store.clearIgnoredOrcaTab(tabId) }
        let location = try store.upsertLocation(
            byExternalKey: key, ticketId: ticketId, locator: .orcaTerminal(terminal), source: .hook)
        if location.ticketId != ticketId {
            let losingTicketId = location.ticketId
            try store.moveLocation(id: location.id, toTicketId: ticketId)
            try deleteIfAbandoned(ticketId: losingTicketId)
        }
    }

    /// 참조한 ChatGPT 대화를 티켓의 `chatgpt_chat` 위치로 붙인다(출처 hook, 키 `chatgpt:<id>`). `jtm retitle`도 쓴다.
    /// 키가 이미 있으면(다른 티켓이든 이 티켓이든) 건드리지 않는다: 다른 티켓에서 뺏지 않는다. 새로 붙였으면 true.
    @discardableResult
    static func attachChatGPTChat(conversationId: String, to ticketId: Int64, store: Store) throws -> Bool {
        let key = "chatgpt:\(conversationId)"
        guard try store.location(byExternalKey: key) == nil else { return false }
        try store.addLocation(
            ticketId: ticketId,
            locator: .chatgptChat(.init(chatId: conversationId, url: "https://chatgpt.com/c/\(conversationId)")),
            source: .hook, externalKey: key)
        return true
    }

    /// 탭을 뺏긴 티켓이 위치가 하나도 남지 않았고 사용자가 손대지 않았으면 지운다: 폴러가 만든 그대로(`inbox`), 고정된 제목,
    /// `next_action`, `note`, `priority`가 모두 없어야 한다. 폴러가 탭만 보고 만든 inbox 티켓이 새 세션에 탭을 넘겨주고 빈 채로
    /// 남는 것을 막는다. 폴러는 티켓을 inbox로만 만들므로, 위치 없는 티켓이 inbox가 아니면 사용자가 상태를 바꾼 것이다
    /// (팝오버의 상태 변경, `jtm set --status`). 그런 티켓과 done으로 닫은 티켓("최근 완료")은 지우지 않는다.
    private func deleteIfAbandoned(ticketId: Int64) throws {
        guard let ticket = try? store.getTicket(id: ticketId),
              ticket.status == .inbox, !ticket.pinnedTitle, !ticket.kept, ticket.nextAction == nil, ticket.note == nil,
              ticket.priority == nil,
              try store.locations(ticketId: ticketId).isEmpty
        else { return }
        try store.deleteTicket(id: ticketId)
    }

    // MARK: Title / project

    /// 프롬프트에서 뽑은 제목. 참조한 ChatGPT 대화 머리말로 시작하면 머리말 규칙(요청 문장 → 참조한 대화 제목 → nil)을 따르고,
    /// 머리말 블록 자체는 절대 제목이 되지 않는다. 그 밖의 프롬프트는 `normalizedTitle`이다.
    static func title(fromPrompt prompt: String) -> String? {
        if let reference = ReferencedConversation.parse(prompt) { return reference.title }
        return normalizedTitle(prompt)
    }

    /// 프롬프트 앞 60자. 줄바꿈과 연속 공백은 한 칸으로 줄이고 앞뒤를 자른다. 비면 nil.
    static func normalizedTitle(_ prompt: String) -> String? {
        let singleLine = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let title = String(singleLine.prefix(titleLimit)).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// `cwd`가 `~/.codex/.chatgpt-projects/` 아래면(ChatGPT 프로젝트 폴더) `ChatGPT`. 아니면
    /// `ORCA_WORKTREE_ID`(`<uuid>::<경로>`)의 경로 끝 이름 → `cwd`의 git 최상위 폴더 이름 → `cwd` 끝 이름.
    private func projectName(env: OrcaEnv?, cwd: String?) -> String? {
        if let cwd, Self.isChatGPTProjectPath(cwd) { return Self.chatGPTProject }
        if let worktree = env?.worktreeId, let name = Self.baseName(ofWorktreeId: worktree) { return name }
        guard let cwd, !cwd.isEmpty else { return nil }
        if let top = projectResolver.gitTopLevel(containing: cwd), let name = Self.baseName(ofPath: top) { return name }
        return Self.baseName(ofPath: cwd)
    }

    /// ChatGPT 프로젝트로 묶는 폴더 아래의 작업 경로에 붙이는 프로젝트 이름.
    public static let chatGPTProject = "ChatGPT"

    /// `…/.codex/.chatgpt-projects/<하위 폴더>` 아래인가(홈 위치는 따지지 않는다: 훅은 `HOME`이 달라도 같은 모양을 본다).
    public static func isChatGPTProjectPath(_ path: String) -> Bool {
        let parts = (path as NSString).standardizingPath.split(separator: "/")
        guard let index = parts.firstIndex(of: ".chatgpt-projects"), index > 0, parts[index - 1] == ".codex" else { return false }
        return index + 1 < parts.count
    }

    private static func baseName(ofWorktreeId id: String) -> String? {
        if let range = id.range(of: "::") { return baseName(ofPath: String(id[range.upperBound...])) }
        return id.hasPrefix("/") ? baseName(ofPath: id) : nil
    }

    private static func baseName(ofPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
