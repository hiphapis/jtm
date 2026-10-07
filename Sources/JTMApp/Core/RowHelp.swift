import Foundation
import JTMCore

// 아이콘/상태/버튼의 설명 문구. 툴팁(`.help`)과 범례가 같은 글을 쓰도록 여기 한 곳에 둔다(뷰는 그리기만 한다).

extension LocationKind {
    /// 왼쪽 목적지 아이콘의 이름.
    public var displayName: String {
        switch self {
        case .orcaTerminal: L10n.string(.locationOrcaTerminal)
        case .codexThread: L10n.string(.locationCodexThread)
        case .claudeChat: L10n.string(.locationClaudeChat)
        case .claudeCode: L10n.string(.locationClaudeCode)
        case .chatgptChat: L10n.string(.locationChatgptChat)
        case .url: L10n.string(.locationURL)
        }
    }

    /// 클릭하면 일어나는 일(`docs/01-product/resolver.md`).
    public var clickEffect: String {
        switch self {
        case .orcaTerminal: L10n.string(.clickOrcaTerminal)
        case .codexThread: L10n.string(.clickCodexThread)
        case .claudeChat: L10n.string(.clickClaudeChat)
        case .claudeCode: L10n.string(.clickClaudeCode)
        case .chatgptChat: L10n.string(.clickChatgptChat)
        case .url: L10n.string(.clickURL)
        }
    }

    /// 툴팁: "Orca 터미널 — 클릭하면 이 터미널로 이동".
    public var helpText: String { "\(displayName) — \(clickEffect)" }

    public static var noDestinationHelp: String { L10n.string(.noDestination) }
}

extension WaitingReason {
    /// 이유 이름(범례, 툴팁 머리).
    public var displayName: String {
        switch self {
        case .permission: L10n.string(.reasonNamePermission)
        case .turnEnd: L10n.string(.reasonNameTurnEnd)
        case .stale: L10n.string(.reasonNameStale)
        case .error: L10n.string(.reasonNameError)
        }
    }

    /// 뜻.
    public var meaning: String {
        switch self {
        case .permission: L10n.string(.reasonMeaningPermission)
        case .turnEnd: L10n.string(.reasonMeaningTurnEnd)
        case .stale: L10n.string(.reasonMeaningStale)
        case .error: L10n.string(.reasonMeaningError)
        }
    }

    /// 이유 표시의 툴팁: "입력 대기: 권한 요청 — 에이전트가 도구 실행 허락을 기다려요".
    public var helpText: String { L10n.string(.reasonHelp, displayName, meaning) }
}

extension TicketStatus {
    /// 섹션 이름과 같다.
    public var displayName: String {
        switch self {
        case .waiting: L10n.string(.sectionWaiting)
        case .active: L10n.string(.sectionActive)
        case .inbox: L10n.string(.sectionInbox)
        case .blocked: L10n.string(.sectionBlocked)
        case .done: L10n.string(.statusDone)
        }
    }

    public var meaning: String {
        switch self {
        case .waiting: L10n.string(.statusMeaningWaiting)
        case .active: L10n.string(.statusMeaningActive)
        case .inbox: L10n.string(.statusMeaningInbox)
        case .blocked: L10n.string(.statusMeaningBlocked)
        case .done: L10n.string(.statusMeaningDone)
        }
    }
}

/// 행 오른쪽의 버튼. 순서가 화면 순서다.
public enum RowAction: CaseIterable, Sendable {
    case keep, editNextAction, done, ignore
    /// 보관함 행에만 있다.
    case restore

    public static var rowActions: [RowAction] { [.keep, .editNextAction, .done, .ignore] }

    /// SF Symbol. 유지는 켜져 있으면 채운 별이다.
    public func symbolName(kept: Bool = false) -> String {
        switch self {
        case .keep: kept ? "star.fill" : "star"
        case .editNextAction: "pencil"
        case .done: "checkmark"
        case .ignore: "trash"
        case .restore: "arrow.uturn.backward"
        }
    }

    /// 선택한 행에 거는 단축키(표시용 글자). 팝오버가 열려 있을 때만 먹는다.
    public var shortcut: String {
        switch self {
        case .keep: "⌘S"
        case .editNextAction: "⌘E"
        case .done: "⌘D"
        case .ignore: "⌘⌫"
        case .restore: "⌘R"
        }
    }

    public func help(kept: Bool = false) -> String {
        switch self {
        case .keep: L10n.string(kept ? .helpKeepOn : .helpKeepOff)
        case .editNextAction: L10n.string(.helpEditNextAction)
        case .done: L10n.string(.helpDone)
        case .ignore: L10n.string(.helpIgnore)
        case .restore: L10n.string(.helpRestore)
        }
    }

    /// 유지(⭐)했거나 next_action/note가 있는 티켓의 🗑을 처음 누르면 이 문구로 바뀌고, 한 번 더 눌러야 지운다.
    public static var ignoreConfirmLabel: String { L10n.string(.ignoreConfirmLabel) }
    public static var ignoreConfirmHelp: String { L10n.string(.ignoreConfirmHelp) }

    /// VoiceOver 이름. ⭐은 이름은 그대로 두고 켜짐/꺼짐을 값(`accessibilityValue`)으로 읽게 한다.
    public var accessibilityLabel: String { label }

    /// VoiceOver 값: ⭐만 "켜짐"/"꺼짐". 나머지는 값이 없다.
    public func accessibilityValue(kept: Bool) -> String? {
        self == .keep ? L10n.string(kept ? .valueOn : .valueOff) : nil
    }

    public var label: String {
        switch self {
        case .keep: L10n.string(.actionKeep)
        case .editNextAction: L10n.string(.actionEditNextAction)
        case .done: L10n.string(.actionDone)
        case .ignore: L10n.string(.actionIgnore)
        case .restore: L10n.string(.actionRestore)
        }
    }
}

/// 범례의 한 줄.
public struct LegendEntry: Identifiable, Equatable, Sendable {
    public var id: String
    /// SF Symbol(없으면 글자 표지만 있다).
    public var symbol: String?
    public var title: String
    public var detail: String
}

/// 푸터 "?" 버튼이 여는 범례: 목적지 아이콘, 상태/이유, 행 버튼, 자동 정리 규칙.
public enum Legend {
    public static var destinations: [LegendEntry] {
        LocationKind.allCases.map {
            LegendEntry(id: "dest-\($0.rawValue)", symbol: $0.symbolName, title: $0.displayName, detail: $0.clickEffect)
        }
    }

    public static var statuses: [LegendEntry] {
        var entries = [TicketStatus.waiting, .active, .inbox, .blocked, .done].map {
            LegendEntry(id: "status-\($0.rawValue)", symbol: nil, title: $0.displayName, detail: $0.meaning)
        }
        let at = entries.firstIndex { $0.id == "status-waiting" }.map { $0 + 1 } ?? entries.count
        entries.insert(contentsOf: WaitingReason.allCases.map {
            LegendEntry(id: "reason-\($0.rawValue)", symbol: nil, title: "  ↳ \($0.displayName)", detail: $0.meaning)
        }, at: at)
        entries.append(LegendEntry(
            id: "status-archive", symbol: nil, title: L10n.string(.sectionArchive), detail: L10n.string(.archiveMeaning)))
        return entries
    }

    public static var actions: [LegendEntry] {
        RowAction.allCases.map {
            LegendEntry(id: "action-\($0)", symbol: $0.symbolName(), title: $0.label, detail: $0.help())
        }
    }
}
