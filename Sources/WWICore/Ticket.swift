import Foundation

public enum TicketStatus: String, Codable, CaseIterable, Sendable {
    case inbox, active, waiting, blocked, done
}

/// `status == .waiting`일 때 왜 기다리는지. 훅은 `turn_end`/`permission`/`error`(API 오류로 턴이 끝남), Orca 폴러는 `stale`을 쓴다.
public enum WaitingReason: String, Codable, CaseIterable, Sendable {
    case turnEnd = "turn_end"
    case permission
    case stale
    case error
}

public struct Ticket: Codable, Equatable, Sendable {
    public var id: Int64
    public var title: String
    public var status: TicketStatus
    public var priority: Int?
    public var project: String?
    public var nextAction: String?
    public var note: String?
    public var pinnedTitle: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastActivityAt: Date
    public var waitingReason: WaitingReason?
    /// 에이전트 세션이 끝난 시각(Claude `SessionEnd`). 세션이 다시 활동하면 지워진다.
    public var endedAt: Date?
    /// "유지(⭐)": 사용자가 직접 챙긴 티켓. 자동 완료·자동 보관을 받지 않는다(`docs/01-product/menubar-ui.md`).
    public var kept: Bool = false
    /// 24시간 활동이 없어 보관함으로 간 시각. 상태(`status`)는 그대로고 목록에서만 빠진다. 새 활동이 있으면 지워진다.
    public var archivedAt: Date? = nil
    /// 시스템이 자동으로 done으로 만든 시각(Claude `SessionEnd`, Orca 탭 사라짐). 사용자가 닫은 티켓에는 없다.
    /// 이 표지가 있는 done 티켓만 같은 세션의 `SessionStart`/`UserPromptSubmit`이 다시 연다(사용자가 닫은 것은 열지 않는다).
    public var autoDoneAt: Date? = nil

    private enum CodingKeys: String, CodingKey {
        case id, title, status, priority, project, nextAction, note, pinnedTitle
        case createdAt, updatedAt, lastActivityAt, waitingReason, endedAt, kept, archivedAt, autoDoneAt
    }

    /// 값이 없는 선택 필드도 키를 생략하지 않고 명시적 `null`로 내보낸다(`--json` 계약).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(status, forKey: .status)
        try container.encode(priority, forKey: .priority)
        try container.encode(project, forKey: .project)
        try container.encode(nextAction, forKey: .nextAction)
        try container.encode(note, forKey: .note)
        try container.encode(pinnedTitle, forKey: .pinnedTitle)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(lastActivityAt, forKey: .lastActivityAt)
        try container.encode(waitingReason, forKey: .waitingReason)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(kept, forKey: .kept)
        try container.encode(archivedAt, forKey: .archivedAt)
        try container.encode(autoDoneAt, forKey: .autoDoneAt)
    }
}
