import Foundation

public enum LocationKind: String, Codable, CaseIterable, Sendable {
    case orcaTerminal = "orca_terminal"
    case codexThread = "codex_thread"
    case claudeChat = "claude_chat"
    case claudeCode = "claude_code"
    case chatgptChat = "chatgpt_chat"
    case url
}

public enum LocationSource: String, Codable, CaseIterable, Sendable {
    case hook
    case orcaSync = "orca_sync"
    case manual
}

/// Kind별 위치 정보. DB에는 payload만 평평한 JSON으로 저장하고(`{"terminalHandle": ...}`),
/// 어떤 payload인지는 `kind` 컬럼으로 구분한다. 그래서 디코딩은 `init(kind:json:)`을 쓴다.
public enum Locator: Equatable, Sendable, Encodable {
    public struct OrcaTerminal: Codable, Equatable, Sendable {
        public var terminalHandle: String
        public var worktreeId: String?
        public var tabId: String?
        public var ptyId: String?
        public var titleHint: String?

        public init(
            terminalHandle: String, worktreeId: String? = nil, tabId: String? = nil,
            ptyId: String? = nil, titleHint: String? = nil
        ) {
            self.terminalHandle = terminalHandle
            self.worktreeId = worktreeId
            self.tabId = tabId
            self.ptyId = ptyId
            self.titleHint = titleHint
        }
    }

    public struct CodexThread: Codable, Equatable, Sendable {
        public var threadId: String
        /// 세션이 돌던 작업 디렉터리. resume 명령이 `cd`할 곳이다(없으면 현재 디렉터리에서 실행).
        public var cwd: String?
        public init(threadId: String, cwd: String? = nil) {
            self.threadId = threadId
            self.cwd = cwd
        }
    }

    public struct ClaudeChat: Codable, Equatable, Sendable {
        public var chatUuid: String
        public var url: String
        public init(chatUuid: String, url: String) {
            self.chatUuid = chatUuid
            self.url = url
        }
    }

    public struct ClaudeCode: Codable, Equatable, Sendable {
        public var sessionId: String
        public var cwd: String
        public init(sessionId: String, cwd: String) {
            self.sessionId = sessionId
            self.cwd = cwd
        }
    }

    public struct ChatGPTChat: Codable, Equatable, Sendable {
        public var chatId: String
        public var url: String
        public init(chatId: String, url: String) {
            self.chatId = chatId
            self.url = url
        }
    }

    public struct URLTarget: Codable, Equatable, Sendable {
        public var url: String
        public init(url: String) { self.url = url }
    }

    case orcaTerminal(OrcaTerminal)
    case codexThread(CodexThread)
    case claudeChat(ClaudeChat)
    case claudeCode(ClaudeCode)
    case chatgptChat(ChatGPTChat)
    case url(URLTarget)

    public var kind: LocationKind {
        switch self {
        case .orcaTerminal: .orcaTerminal
        case .codexThread: .codexThread
        case .claudeChat: .claudeChat
        case .claudeCode: .claudeCode
        case .chatgptChat: .chatgptChat
        case .url: .url
        }
    }

    public init(kind: LocationKind, json: Data) throws {
        let decoder = JSONDecoder()
        switch kind {
        case .orcaTerminal: self = .orcaTerminal(try decoder.decode(OrcaTerminal.self, from: json))
        case .codexThread: self = .codexThread(try decoder.decode(CodexThread.self, from: json))
        case .claudeChat: self = .claudeChat(try decoder.decode(ClaudeChat.self, from: json))
        case .claudeCode: self = .claudeCode(try decoder.decode(ClaudeCode.self, from: json))
        case .chatgptChat: self = .chatgptChat(try decoder.decode(ChatGPTChat.self, from: json))
        case .url: self = .url(try decoder.decode(URLTarget.self, from: json))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .orcaTerminal(let payload): try payload.encode(to: encoder)
        case .codexThread(let payload): try payload.encode(to: encoder)
        case .claudeChat(let payload): try payload.encode(to: encoder)
        case .claudeCode(let payload): try payload.encode(to: encoder)
        case .chatgptChat(let payload): try payload.encode(to: encoder)
        case .url(let payload): try payload.encode(to: encoder)
        }
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public struct Location: Encodable, Equatable, Sendable {
    public var id: Int64
    public var ticketId: Int64
    public var locator: Locator
    public var source: LocationSource
    public var externalKey: String?
    public var lastSeenAt: Date
    /// 폴러가 이 위치(탭 등)를 더는 찾지 못한 시각. 티켓 상태는 바꾸지 않는 표시일 뿐이다.
    public var goneAt: Date?
    /// 폴러가 이 위치를 연속으로 못 찾은 횟수(`gone_at`을 찍기 전의 유예). 다시 보이면 0으로 돌아간다. `--json`에는 내보내지 않는다.
    public var missCount: Int = 0

    public var kind: LocationKind { locator.kind }

    private enum CodingKeys: String, CodingKey {
        case id, ticketId, kind, locator, source, externalKey, lastSeenAt, goneAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(ticketId, forKey: .ticketId)
        try container.encode(kind, forKey: .kind)
        try container.encode(locator, forKey: .locator)
        try container.encode(source, forKey: .source)
        try container.encode(externalKey, forKey: .externalKey)
        try container.encode(lastSeenAt, forKey: .lastSeenAt)
        try container.encode(goneAt, forKey: .goneAt)
    }
}

extension Sequence where Element == Location {
    /// 주 위치. 정의는 `Resolver.choose(from:)` 하나뿐이다(`jtm ls`의 표시와 `jtm go`의 대상이 같다).
    public var primary: Location? { Resolver.choose(from: Array(self)) }
}
