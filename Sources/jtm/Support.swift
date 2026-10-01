import ArgumentParser
import Foundation
import JTMCore

extension TicketStatus: ExpressibleByArgument {}

/// DB 경로를 정하는 곳은 CLI뿐이다: `JTM_DB_PATH`가 있으면 그것, 없으면 Application Support.
func openStore() throws -> Store {
    try Store(path: databasePath())
}

func databasePath() -> String {
    if let override = ProcessInfo.processInfo.environment["JTM_DB_PATH"], !override.isEmpty {
        return override
    }
    return NSHomeDirectory() + "/Library/Application Support/jtm/jtm.sqlite"
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

/// `--json` 출력용: 티켓 필드에 locations를 덧붙인다.
struct TicketDetail: Encodable {
    let ticket: Ticket
    let locations: [Location]

    private enum CodingKeys: String, CodingKey { case locations }

    func encode(to encoder: Encoder) throws {
        try ticket.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(locations, forKey: .locations)
    }
}

extension LocationKind {
    var icon: String {
        switch self {
        case .orcaTerminal: "🖥"
        case .codexThread: "🧵"
        case .claudeChat: "💬"
        case .claudeCode: "⌘"
        case .chatgptChat: "🤖"
        case .url: "🔗"
        }
    }

    var label: String {
        switch self {
        case .orcaTerminal: "orca"
        case .codexThread: "codex"
        case .claudeChat: "claude"
        case .claudeCode: "claude-code"
        case .chatgptChat: "chatgpt"
        case .url: "url"
        }
    }
}

func nilIfEmpty(_ text: String) -> String? {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
}

/// `--json` 모드에서 쓰기 명령(add/set/done)의 성공 출력.
struct WriteEnvelope: Encodable {
    var ok = true
    var id: Int64
}

/// `--json` 모드의 오류 출력.
struct ErrorEnvelope: Encodable {
    var ok = false
    var error: String
}

/// `waiting`이면 이유를 붙여 "waiting(permission)"처럼 보여준다.
func statusLabel(_ ticket: Ticket) -> String {
    guard ticket.status == .waiting, let reason = ticket.waitingReason else { return ticket.status.rawValue }
    return "\(ticket.status.rawValue)(\(reason.rawValue))"
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}
