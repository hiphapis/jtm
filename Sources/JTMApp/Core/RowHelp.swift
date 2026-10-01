import Foundation
import JTMCore

// 아이콘/상태/버튼의 설명 문구. 툴팁(`.help`)과 범례가 같은 글을 쓰도록 여기 한 곳에 둔다(뷰는 그리기만 한다).

extension LocationKind {
    /// 왼쪽 목적지 아이콘의 이름.
    public var displayName: String {
        switch self {
        case .orcaTerminal: "Orca 터미널"
        case .codexThread: "Codex 스레드"
        case .claudeChat: "Claude 채팅"
        case .claudeCode: "Claude Code 세션"
        case .chatgptChat: "ChatGPT 대화"
        case .url: "링크"
        }
    }

    /// 클릭하면 일어나는 일(`docs/01-product/resolver.md`).
    public var clickEffect: String {
        switch self {
        case .orcaTerminal: "클릭하면 이 터미널로 이동"
        case .codexThread: "클릭하면 Codex에서 이 스레드를 열어요"
        case .claudeChat: "클릭하면 브라우저에서 이 채팅을 열어요"
        case .claudeCode: "클릭하면 연결된 Orca 터미널로 이동하고, 안 되면 재개 명령을 클립보드에 복사해요"
        case .chatgptChat: "클릭하면 ChatGPT에서 이 대화를 열어요"
        case .url: "클릭하면 기본 브라우저로 열어요"
        }
    }

    /// 툴팁: "Orca 터미널 — 클릭하면 이 터미널로 이동".
    public var helpText: String { "\(displayName) — \(clickEffect)" }

    public static let noDestinationHelp = "이동할 위치가 없어요"
}

extension WaitingReason {
    /// 이유 이름(범례, 툴팁 머리).
    public var displayName: String {
        switch self {
        case .permission: "권한 요청"
        case .turnEnd: "턴 종료"
        case .stale: "멈춤"
        case .error: "오류"
        }
    }

    /// 뜻.
    public var meaning: String {
        switch self {
        case .permission: "에이전트가 도구 실행 허락을 기다려요"
        case .turnEnd: "에이전트가 답을 마치고 다음 지시를 기다려요"
        case .stale: "10분 넘게 새 활동이 없어요"
        case .error: "API 오류 등으로 턴이 실패했어요"
        }
    }

    /// 이유 표시의 툴팁: "입력 대기: 권한 요청 — 에이전트가 도구 실행 허락을 기다려요".
    public var helpText: String { "입력 대기: \(displayName) — \(meaning)" }
}

extension TicketStatus {
    /// 섹션 이름과 같다.
    public var displayName: String {
        switch self {
        case .waiting: "내 입력 대기"
        case .active: "진행 중"
        case .inbox: "Inbox"
        case .blocked: "Blocked"
        case .done: "완료"
        }
    }

    public var meaning: String {
        switch self {
        case .waiting: "내가 봐야 할 일이에요. 메뉴바 배지에 센다"
        case .active: "에이전트가 일하는 중이에요"
        case .inbox: "자동으로 잡혔지만 아직 분류하지 않았어요"
        case .blocked: "막혀서 멈춘 일이에요"
        case .done: "끝난 일이에요. 최근 24시간 안에 끝난 것만 보여요"
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
        case .keep: kept ? "유지 해제 — 다시 자동 정리 대상이 돼요 (⌘S)" : "유지(⭐) — 자동 완료·자동 보관에서 빼요 (⌘S)"
        case .editNextAction: "next_action 편집 (⌘E)"
        case .done: "완료로 표시 (⌘D)"
        case .ignore: "무시 — 티켓을 지우고 이 세션을 다시 모으지 않아요 (⌘⌫, 5초 안에 되돌릴 수 있어요)"
        case .restore: "되살리기 — 보관함에서 꺼내 유지(⭐)로 둬요 (⌘R)"
        }
    }

    /// 유지(⭐)했거나 next_action/note가 있는 티켓의 🗑을 처음 누르면 이 문구로 바뀌고, 한 번 더 눌러야 지운다.
    public static let ignoreConfirmLabel = "정말 지울까요?"
    public static let ignoreConfirmHelp = "한 번 더 누르면 이 티켓을 지워요 (5초 안에 되돌릴 수 있어요). 다른 곳을 누르거나 Esc로 취소해요"

    /// VoiceOver 이름. ⭐은 이름은 그대로 두고 켜짐/꺼짐을 값(`accessibilityValue`)으로 읽게 한다.
    public var accessibilityLabel: String { label }

    /// VoiceOver 값: ⭐만 "켜짐"/"꺼짐". 나머지는 값이 없다.
    public func accessibilityValue(kept: Bool) -> String? {
        self == .keep ? (kept ? "켜짐" : "꺼짐") : nil
    }

    public var label: String {
        switch self {
        case .keep: "유지"
        case .editNextAction: "next_action 편집"
        case .done: "완료"
        case .ignore: "무시"
        case .restore: "되살리기"
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
            id: "status-archive", symbol: nil, title: "보관함", detail: "24시간 동안 활동이 없어 자동으로 치운 티켓이에요. 새 활동이 있으면 돌아와요"))
        return entries
    }

    public static var actions: [LegendEntry] {
        RowAction.allCases.map {
            LegendEntry(id: "action-\($0)", symbol: $0.symbolName(), title: $0.label, detail: $0.help())
        }
    }
}
