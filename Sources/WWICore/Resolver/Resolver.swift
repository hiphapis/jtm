import Foundation

/// 실행 예정인 명령. `--dry-run`이 그대로 출력한다.
public struct PlannedCommand: Equatable, Sendable, Encodable {
    public var argv: [String]
    public var stdin: String?
    public var note: String?

    public init(_ argv: [String], stdin: String? = nil, note: String? = nil) {
        self.argv = argv
        self.stdin = stdin
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case argv, stdin, note }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(argv, forKey: .argv)
        try container.encode(stdin, forKey: .stdin)
        try container.encode(note, forKey: .note)
    }
}

public struct ResolveResult: Sendable {
    public var ok: Bool
    public var message: String
    /// 실제로 연 위치(또는 resume 명령을 복사한 위치). claude_code가 orca_terminal로 위임되면 요청한 위치와 다르다.
    public var location: Location
    /// 저장해야 할 새 locator(handle 갱신, tabId/worktreeId/ptyId 보강). 바뀐 게 없으면 nil.
    public var updatedLocator: Locator?
    /// resume 명령을 클립보드에 복사했다(이동은 하지 않았다). UI가 "복사했어요"를 보여주고 팝오버를 닫지 않는 근거다.
    public var copiedToClipboard = false
}

public enum ResolveError: Error, CustomStringConvertible {
    case orcaNotFound
    case noLocations(ticketId: Int64)
    case locationNotInTicket(locationId: Int64, ticketId: Int64)
    case disallowedTarget(String)

    public var description: String {
        switch self {
        case .orcaNotFound:
            "orca CLI not found: set ORCA_CLI_COMMAND or put `orca` on PATH (or install /usr/local/bin/orca)"
        case .noLocations(let ticketId): "ticket \(ticketId) has no locations"
        case .locationNotInTicket(let locationId, let ticketId):
            "location \(locationId) does not belong to ticket \(ticketId)"
        case .disallowedTarget(let target): Resolver.refusal(for: target)
        }
    }
}

/// Location의 kind별 "이동" 어댑터. → docs/01-product/resolver.md
public struct Resolver {
    /// `orca`는 UI 전환까지 기다리므로 넉넉하게, `open`/`pbcopy`는 짧게.
    static let orcaTimeout: TimeInterval = 8
    static let openTimeout: TimeInterval = 3
    /// `open -a Orca` 직후 런타임이 준비될 때까지 handle 오류가 아닌 실패를 재시도하는 간격(합계 약 5초).
    static let orcaRetryDelays: [TimeInterval] = [0.25, 0.5, 1, 1.5, 1.75]
    static let terminalListLimit = "500"
    /// `open`에 넘겨도 되는 스킴. 그 밖(file:, 옵션처럼 보이는 값 등)은 거부한다.
    static let openSchemes: Set<String> = ["http", "https", "codex", "claude"]

    let runner: CommandRunner
    let orca: String?
    let sleep: (TimeInterval) -> Void

    public init(
        runner: CommandRunner, orcaCommand: String?,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.runner = runner
        self.orca = orcaCommand
        self.sleep = sleep
    }

    /// 이동 대상의 유일한 정의(`wwi ls`와 `wwi go`가 함께 쓴다):
    /// 우선순위: orca_terminal → 에이전트 세션(codex_thread, claude_code) → 그 밖(chatgpt_chat, url, claude_chat).
    /// 각 단계에서 lastSeenAt이 가장 최근인 것, 동률이면 id가 작은 쪽. 참조한 ChatGPT 대화를 나중에 붙여도 Codex 스레드가 주 위치다.
    public static func choose(from locations: [Location]) -> Location? {
        func newest(_ candidates: [Location]) -> Location? {
            candidates.min { ($1.lastSeenAt, $0.id) < ($0.lastSeenAt, $1.id) }
        }
        return newest(locations.filter { $0.kind == .orcaTerminal })
            ?? newest(locations.filter { $0.kind == .codexThread || $0.kind == .claudeCode })
            ?? newest(locations)
    }

    /// 실제로 움직일 위치: claude_code는 같은 티켓의 orca_terminal이 있으면 그쪽으로 위임한다.
    public static func delegate(_ location: Location, among all: [Location]) -> Location {
        if case .claudeCode = location.locator,
           let terminal = choose(from: all.filter { $0.kind == .orcaTerminal }) {
            return terminal
        }
        return location
    }

    // MARK: Plan (dry-run)

    public func plan(_ location: Location, among all: [Location]) throws -> [PlannedCommand] {
        let target = Self.delegate(location, among: all)
        switch target.locator {
        case .orcaTerminal(let terminal):
            let orca = try requireOrca()
            var steps = [
                PlannedCommand(["open", "-a", "Orca"]),
                PlannedCommand(Self.switchArgv(orca, terminal.terminalHandle)),
                PlannedCommand(
                    Self.listArgv(orca),
                    note: "only if the switch reports a stale handle, or ptyId is not stored yet"),
            ]
            if let fallback = Self.resumeFallback(requested: location, among: all) {
                steps.append(PlannedCommand(
                    ["pbcopy"], stdin: fallback.command, note: "fallback if the Orca terminal cannot be reached"))
            }
            return steps
        case .codexThread(let thread):
            return [PlannedCommand(["open", "codex://threads/\(thread.threadId)"])]
        case .chatgptChat(let chat):
            var steps = [PlannedCommand(["open", "codex://threads/\(chat.chatId)"])]
            if Self.isOpenable(chat.url) {
                steps.append(PlannedCommand(["open", chat.url], note: "fallback if the previous command fails"))
            }
            return steps
        case .claudeChat(let chat):
            return [try openStep(chat.url)]
        case .url(let target):
            return [try openStep(target.url)]
        case .claudeCode(let session):
            return [PlannedCommand(["pbcopy"], stdin: Self.claudeResumeCommand(session))]
        }
    }

    private func openStep(_ target: String) throws -> PlannedCommand {
        guard Self.isOpenable(target) else { throw ResolveError.disallowedTarget(target) }
        return PlannedCommand(["open", target])
    }

    // MARK: Resolve

    public func resolve(_ location: Location, among all: [Location]) -> ResolveResult {
        let target = Self.delegate(location, among: all)
        switch target.locator {
        case .orcaTerminal(let stored):
            switch moveToOrcaTerminal(target, stored) {
            case .moved(let result):
                return result
            case .failed(let message, let recoveryFailed):
                // 위임된 claude_code는 어떤 실패든, orca_terminal은 handle 복구까지 실패했을 때 resume 명령을 복사한다.
                let delegated = target.id != location.id
                guard recoveryFailed || delegated,
                      let fallback = Self.resumeFallback(requested: location, among: all)
                else { return ResolveResult(ok: false, message: message, location: target, updatedLocator: nil) }
                let copied = copy(fallback.command)
                return ResolveResult(
                    ok: copied.succeeded,
                    message: "\(message); "
                        + (copied.succeeded ? "copied resume command" : "pbcopy also failed: \(Self.detail(copied))"),
                    location: fallback.location, updatedLocator: nil, copiedToClipboard: copied.succeeded)
            }
        case .codexThread(let thread):
            return open("codex://threads/\(thread.threadId)", for: target)
        case .chatgptChat(let chat):
            let app = open("codex://threads/\(chat.chatId)", for: target)
            return app.ok ? app : open(chat.url, for: target, prefix: "ChatGPT app link failed; ")
        case .claudeChat(let chat):
            return open(chat.url, for: target)
        case .url(let destination):
            return open(destination.url, for: target)
        case .claudeCode(let session):
            let copied = copy(Self.claudeResumeCommand(session))
            return ResolveResult(
                ok: copied.succeeded,
                message: copied.succeeded ? "copied resume command" : "pbcopy failed: \(Self.detail(copied))",
                location: target, updatedLocator: nil, copiedToClipboard: copied.succeeded)
        }
    }

    private func copy(_ text: String) -> CommandResult {
        runner.run(["pbcopy"], stdin: text, timeout: Self.openTimeout)
    }

    private func open(_ target: String, for location: Location, prefix: String = "") -> ResolveResult {
        guard Self.isOpenable(target) else {
            return ResolveResult(ok: false, message: prefix + Self.refusal(for: target), location: location, updatedLocator: nil)
        }
        let result = runner.run(["open", target], stdin: nil, timeout: Self.openTimeout)
        return ResolveResult(
            ok: result.succeeded,
            message: prefix + (result.succeeded ? "opened \(target)" : "open \(target) failed: \(Self.detail(result))"),
            location: location, updatedLocator: nil)
    }

    static func isOpenable(_ target: String) -> Bool {
        guard !target.hasPrefix("-"), let scheme = URL(string: target)?.scheme?.lowercased() else { return false }
        return openSchemes.contains(scheme)
    }

    static func refusal(for target: String) -> String {
        "refusing to open \(target): only http, https, codex and claude URLs are allowed"
    }

    // MARK: orca_terminal

    private struct Focus: Decodable {
        var tabId: String?
        var worktreeId: String?
    }

    private struct ListedTerminal: Decodable {
        var handle: String
        var ptyId: String?
        var tabId: String?
        var worktreeId: String?
    }

    /// 배열 원소 하나가 깨져도(예: handle 누락) 목록 전체를 버리지 않는다.
    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    private struct OrcaEnvelope<Result: Decodable>: Decodable {
        struct Failure: Decodable {
            var code: String?
            var message: String?
        }
        var ok: Bool
        var result: Result?
        var error: Failure?
    }

    private struct SwitchResult: Decodable { var focus: Focus? }
    private struct ListResult: Decodable {
        var terminals: [Lossy<ListedTerminal>]
        var truncated: Bool?
    }

    private struct Listing {
        var terminals: [ListedTerminal]
        var truncated: Bool
    }

    private struct OrcaFailure: Error, CustomStringConvertible {
        var description: String
        var code: String?
        var timedOut = false

        /// handle이 무효/없음일 때만 복구(list → 재매칭)를 시도한다.
        var isStaleHandle: Bool {
            code == "terminal_handle_stale" || (code ?? "").contains("not_found")
        }
    }

    private enum OrcaMove {
        case moved(ResolveResult)
        /// `recoveryFailed`: handle이 무효라서 복구를 시도했지만 실패한 경우.
        case failed(message: String, recoveryFailed: Bool)
    }

    private func moveToOrcaTerminal(_ location: Location, _ stored: Locator.OrcaTerminal) -> OrcaMove {
        guard let orca else { return .failed(message: ResolveError.orcaNotFound.description, recoveryFailed: false) }

        _ = runner.run(["open", "-a", "Orca"], stdin: nil, timeout: Self.openTimeout)

        var target = stored
        var listing: Listing?
        var attempt = orcaSwitch(orca, stored.terminalHandle)

        // 콜드 스타트: `open -a Orca`는 런타임이 준비되기 전에 돌아온다. handle 오류가 아닌 실패는 잠깐 재시도한다.
        var delays = Self.orcaRetryDelays[...]
        while case .failure(let failure) = attempt, !failure.isStaleHandle, !failure.timedOut,
              let delay = delays.popFirst() {
            sleep(delay)
            attempt = orcaSwitch(orca, stored.terminalHandle)
        }

        var recovered: ListedTerminal?
        if case .failure(let failure) = attempt {
            guard failure.isStaleHandle else {
                return .failed(message: "orca switch failed (\(failure)); is Orca running and ready?", recoveryFailed: false)
            }
            // handle이 무효일 때: ptyId → tabId 순으로 새 handle을 찾는다. 제목 매칭은 하지 않는다.
            let found: Listing
            switch orcaList(orca) {
            case .failure(let listFailure):
                return .failed(
                    message: "terminal handle is stale (\(failure)) and terminals could not be listed (\(listFailure))",
                    recoveryFailed: true)
            case .success(let listed): found = listed
            }
            listing = found
            guard let match = Self.findRenamed(stored, in: found.terminals) else {
                return .failed(
                    message: "terminal handle is stale (\(failure)) and no listed terminal matches the stored ptyId/tabId"
                        + (found.truncated ? " (the terminal list was truncated)" : "")
                        + "; try `orca search` and run its resumeCommand",
                    recoveryFailed: true)
            }
            guard match.handle != stored.terminalHandle else {
                return .failed(
                    message: "orca switch failed (\(failure)) although the handle is still listed", recoveryFailed: true)
            }
            recovered = match
            target.terminalHandle = match.handle
            target.ptyId = match.ptyId ?? target.ptyId
            target.tabId = Self.permanentTabId(match.tabId)
            target.worktreeId = match.worktreeId ?? target.worktreeId
            attempt = orcaSwitch(orca, match.handle)
            if case .failure(let retryFailure) = attempt {
                return .failed(
                    message: "orca switch to recovered handle \(match.handle) failed (\(retryFailure))",
                    recoveryFailed: true)
            }
        }

        if case .success(let focus) = attempt {
            if let tabId = Self.permanentTabId(focus?.tabId) { target.tabId = tabId }
            if let worktreeId = focus?.worktreeId { target.worktreeId = worktreeId }
        }
        // ptyId가 없으면 이후 handle 복구에 쓸 매칭 키가 없으므로 지금 채워 둔다.
        if target.ptyId == nil {
            if listing == nil, case .success(let listed) = orcaList(orca) { listing = listed }
            target.ptyId = listing?.terminals.first { $0.handle == target.terminalHandle }?.ptyId
        }

        return .moved(ResolveResult(
            ok: true,
            message: recovered == nil
                ? "switched to Orca terminal \(target.terminalHandle)"
                : "switched to Orca terminal \(target.terminalHandle) (handle was stale: \(stored.terminalHandle))",
            location: location,
            updatedLocator: target == stored ? nil : .orcaTerminal(target)))
    }

    /// `pty:`로 시작하는 tabId는 Orca 재시작 직후의 임시값이라 매칭 키로도 저장값으로도 쓰지 않는다.
    private static func permanentTabId(_ tabId: String?) -> String? {
        guard let tabId, !tabId.isEmpty, !tabId.hasPrefix("pty:") else { return nil }
        return tabId
    }

    private static func findRenamed(_ stored: Locator.OrcaTerminal, in list: [ListedTerminal]) -> ListedTerminal? {
        if let ptyId = stored.ptyId, let match = list.first(where: { $0.ptyId == ptyId }) { return match }
        if let tabId = permanentTabId(stored.tabId), let match = list.first(where: { $0.tabId == tabId }) {
            return match
        }
        return nil
    }

    private func orcaSwitch(_ orca: String, _ handle: String) -> Swift.Result<Focus?, OrcaFailure> {
        let result = runner.run(Self.switchArgv(orca, handle), stdin: nil, timeout: Self.orcaTimeout)
        return Self.decode(OrcaEnvelope<SwitchResult>.self, result).map { $0.result?.focus }
    }

    private func orcaList(_ orca: String) -> Swift.Result<Listing, OrcaFailure> {
        let result = runner.run(Self.listArgv(orca), stdin: nil, timeout: Self.orcaTimeout)
        return Self.decode(OrcaEnvelope<ListResult>.self, result).map {
            Listing(
                terminals: ($0.result?.terminals ?? []).compactMap(\.value),
                truncated: $0.result?.truncated ?? false)
        }
    }

    /// 성공 = exit 0 이고 JSON의 ok == true. stdout 앞에 잡음이 붙어도 첫 `{`부터 읽는다.
    private static func decode<Result: Decodable>(
        _ type: OrcaEnvelope<Result>.Type, _ result: CommandResult
    ) -> Swift.Result<OrcaEnvelope<Result>, OrcaFailure> {
        if result.timedOut { return .failure(OrcaFailure(description: detail(result), timedOut: true)) }
        let text = result.stdout.firstIndex(of: "{").map { String(result.stdout[$0...]) } ?? result.stdout
        let envelope = try? JSONDecoder().decode(type, from: Data(text.utf8))
        if result.succeeded, let envelope, envelope.ok { return .success(envelope) }
        if let error = envelope?.error {
            let code = error.code ?? error.message
            return .failure(OrcaFailure(description: code ?? "error", code: code))
        }
        return .failure(OrcaFailure(description: result.succeeded ? "unexpected output" : detail(result)))
    }

    // MARK: Helpers

    private func requireOrca() throws -> String {
        guard let orca else { throw ResolveError.orcaNotFound }
        return orca
    }

    private static func switchArgv(_ orca: String, _ handle: String) -> [String] {
        [orca, "terminal", "switch", "--terminal", handle, "--json"]
    }

    private static func listArgv(_ orca: String) -> [String] {
        [orca, "terminal", "list", "--json", "--limit", terminalListLimit]
    }

    /// 항상 작은따옴표로 감싼다(값 안의 작은따옴표는 `'\''`로 이스케이프).
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func claudeResumeCommand(_ session: Locator.ClaudeCode) -> String {
        "cd \(shellQuote(session.cwd)) && claude --resume \(shellQuote(session.sessionId))"
    }

    static func codexResumeCommand(_ thread: Locator.CodexThread) -> String {
        let resume = "codex resume \(shellQuote(thread.threadId))"
        guard let cwd = thread.cwd, !cwd.isEmpty else { return resume }
        return "cd \(shellQuote(cwd)) && \(resume)"
    }

    /// Orca 터미널로 못 갈 때 클립보드에 넣을 resume 명령: 요청한 claude_code 위치 → 같은 티켓의 claude_code → codex_thread.
    static func resumeFallback(requested: Location, among all: [Location]) -> (location: Location, command: String)? {
        if case .claudeCode(let session) = requested.locator { return (requested, claudeResumeCommand(session)) }
        if let claude = choose(from: all.filter { $0.kind == .claudeCode }), case .claudeCode(let session) = claude.locator {
            return (claude, claudeResumeCommand(session))
        }
        if let codex = choose(from: all.filter { $0.kind == .codexThread }), case .codexThread(let thread) = codex.locator {
            return (codex, codexResumeCommand(thread))
        }
        return nil
    }

    private static func detail(_ result: CommandResult) -> String {
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "exit \(result.exitCode)" : "exit \(result.exitCode): \(text)"
    }
}

// MARK: Ticket-level entry points

extension Resolver {
    /// 티켓에서 이동할 위치를 정한다. `locationId`가 있으면 그 위치(같은 티켓 소속이어야 함).
    private static func target(ticketId: Int64, locationId: Int64?, in locations: [Location]) throws -> Location {
        if let locationId {
            guard let found = locations.first(where: { $0.id == locationId }) else {
                throw ResolveError.locationNotInTicket(locationId: locationId, ticketId: ticketId)
            }
            return found
        }
        guard let chosen = choose(from: locations) else { throw ResolveError.noLocations(ticketId: ticketId) }
        return chosen
    }

    /// `location`은 실제로 움직일 위치라서(위임 반영) 실제 실행 결과의 `location`과 같다.
    public func planGo(
        ticketId: Int64, locationId: Int64? = nil, store: Store
    ) throws -> (location: Location, commands: [PlannedCommand]) {
        _ = try store.getTicket(id: ticketId)
        let all = try store.locations(ticketId: ticketId)
        let requested = try Self.target(ticketId: ticketId, locationId: locationId, in: all)
        return (Self.delegate(requested, among: all), try plan(requested, among: all))
    }

    /// 이동을 실행한다. 성공하면 바뀐 locator만 저장하고 티켓의 `updatedAt`만 갱신한다
    /// (`lastActivityAt`은 에이전트 활동/상태 변경 전용이라 건드리지 않는다).
    public func go(ticketId: Int64, locationId: Int64? = nil, store: Store) throws -> ResolveResult {
        _ = try store.getTicket(id: ticketId)
        let all = try store.locations(ticketId: ticketId)
        let requested = try Self.target(ticketId: ticketId, locationId: locationId, in: all)
        let result = resolve(requested, among: all)
        guard result.ok else { return result }
        if let locator = result.updatedLocator {
            try store.updateLocation(id: result.location.id, locator: locator)
        }
        try store.patchTicket(id: ticketId)
        return result
    }
}
