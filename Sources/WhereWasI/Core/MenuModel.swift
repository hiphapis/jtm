import Foundation
import WWICore

/// 팝오버의 섹션. 선언 순서가 화면 순서다. `archive`(보관함)는 상태와 상관없이 보관된 티켓이 간다.
public enum MenuSection: Int, CaseIterable, Sendable {
    case waiting, active, inbox, blocked, done, archive

    public var title: String {
        switch self {
        case .waiting: L10n.string(.sectionWaiting)
        case .active: L10n.string(.sectionActive)
        case .inbox: L10n.string(.sectionInbox)
        case .blocked: L10n.string(.sectionBlocked)
        case .done: L10n.string(.sectionDone)
        case .archive: L10n.string(.sectionArchive)
        }
    }

    /// 접었다 펼 수 있는 섹션(최근 완료, 보관함).
    public var isCollapsible: Bool { self == .done || self == .archive }

    init(_ status: TicketStatus) {
        switch status {
        case .waiting: self = .waiting
        case .active: self = .active
        case .inbox: self = .inbox
        case .blocked: self = .blocked
        case .done: self = .done
        }
    }
}

extension Ticket {
    /// 🗑을 한 번에 누르면 안 되는 티켓: 사용자가 챙겼거나(⭐) 손으로 쓴 내용(next_action, note)이 있다.
    /// 지우면 5초 뒤 영구 소실이라 인라인 확인을 한 번 더 거친다. 손대지 않은 자동 티켓은 곧바로 지운다.
    public var needsIgnoreConfirmation: Bool {
        kept || !(nextAction ?? "").isEmpty || !(note ?? "").isEmpty
    }
}

extension WaitingReason {
    /// 대기 이유 표시(권한/턴 종료/멈춤/오류).
    public var label: String {
        switch self {
        case .permission: L10n.string(.reasonLabelPermission)
        case .turnEnd: L10n.string(.reasonLabelTurnEnd)
        case .stale: L10n.string(.reasonLabelStale)
        case .error: L10n.string(.reasonLabelError)
        }
    }
}

extension LocationKind {
    /// 목적지 아이콘(SF Symbol).
    public var symbolName: String {
        switch self {
        case .orcaTerminal: "terminal"
        case .codexThread: "curlybraces"
        case .claudeChat: "bubble.left"
        case .claudeCode: "chevron.left.forwardslash.chevron.right"
        case .chatgptChat: "bubble.left.and.bubble.right"
        case .url: "link"
        }
    }
}

/// 현재 언어의 상대 시간: 영어는 just now · 5m ago · 3h ago · 2d ago, 한국어는 방금 · N분 전 · N시간 전 · N일 전.
public enum AppRelativeTime {
    public static func string(from date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return L10n.string(.timeJustNow)
        case ..<3_600: return L10n.string(.timeMinutes, seconds / 60)
        case ..<86_400: return L10n.string(.timeHours, seconds / 3_600)
        default: return L10n.string(.timeDays, seconds / 86_400)
        }
    }
}

/// 행 하나에 그릴 값. 뷰는 이것만 읽는다.
public struct MenuRow: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var title: String
    public var project: String?
    public var nextAction: String?
    public var status: TicketStatus
    public var reasonLabel: String?
    public var destination: LocationKind?
    public var pinnedTitle: Bool
    public var lastActivityAt: Date
    /// 유지(⭐)한 티켓: 자동 완료·자동 보관을 받지 않는다.
    public var kept: Bool
    /// 보관함에 있는 티켓.
    public var archived: Bool
    public var waitingReason: WaitingReason?
    /// 🗑을 누르면 "정말 지울까요?"를 한 번 더 묻는 티켓인가(`Ticket.needsIgnoreConfirmation`).
    public var needsIgnoreConfirmation: Bool

    init(_ listing: TicketListing) {
        let ticket = listing.ticket
        id = ticket.id
        title = ticket.title
        project = ticket.project.flatMap { $0.isEmpty ? nil : $0 }
        nextAction = ticket.nextAction.flatMap { $0.isEmpty ? nil : $0 }
        status = ticket.status
        reasonLabel = ticket.status == .waiting ? ticket.waitingReason?.label : nil
        // `wwi ls`/`wwi go`와 같은 정의(Resolver.choose)다.
        destination = Resolver.choose(from: listing.locations)?.kind
        pinnedTitle = ticket.pinnedTitle
        lastActivityAt = ticket.lastActivityAt
        kept = ticket.kept
        archived = ticket.archivedAt != nil
        waitingReason = ticket.status == .waiting ? ticket.waitingReason : nil
        needsIgnoreConfirmation = ticket.needsIgnoreConfirmation
    }

    /// 왼쪽 목적지 아이콘의 툴팁(종류와 클릭하면 일어나는 일).
    public var destinationHelp: String { destination.map(\.helpText) ?? LocationKind.noDestinationHelp }

    /// 상태/이유 표시의 툴팁. 이유 표시(대기 중)가 없는 행은 nil.
    public var reasonHelp: String? { waitingReason?.helpText }

    /// 이 행에 보이는 버튼들(오른쪽, 왼쪽에서 오른쪽 순서). 보관함 행은 "되살리기" 하나다.
    public var actions: [RowAction] { archived ? [.restore] : [.keep, .editNextAction, .done, .ignore] }

    public func ago(now: Date) -> String { AppRelativeTime.string(from: lastActivityAt, now: now) }

    /// VoiceOver가 행 하나를 읽는 문장: 제목, 프로젝트, 상태/이유, 목적지, 경과 시간, next_action, 유지 여부.
    /// 행 하나가 VoiceOver에는 한 요소라서, 행 버튼과 같은 동작이 VoiceOver 동작 목록으로도 나온다(`actions`).
    public func accessibilityLabel(now: Date) -> String {
        var parts = [title]
        if let project { parts.append(L10n.string(.rowProject, project)) }
        if status == .waiting {
            parts.append(waitingReason.map { L10n.string(.rowWaitingReason, $0.displayName) } ?? L10n.string(.rowWaiting))
        } else if archived {
            parts.append(L10n.string(.sectionArchive))
        } else {
            parts.append(status.displayName)
        }
        parts.append(destination?.displayName ?? L10n.string(.rowNoDestination))
        parts.append(ago(now: now))
        if let nextAction { parts.append(L10n.string(.rowNextAction, nextAction)) }
        if kept { parts.append(L10n.string(.rowKept)) }
        return parts.joined(separator: ", ")
    }
}

public struct MenuSectionModel: Identifiable, Equatable, Sendable {
    public var section: MenuSection
    public var rows: [MenuRow]
    /// 접힌 섹션은 제목과 개수만 보이고 행은 화면에도, 방향키 선택 대상에도 없다.
    public var collapsed: Bool
    public var id: Int { section.rawValue }
    public var visibleRows: [MenuRow] { collapsed ? [] : rows }
}

/// 팝오버의 표시 상태(순수 값): 목록, 검색어, 선택, 접힘. UI 프레임워크를 모른다.
public struct MenuState: Equatable, Sendable {
    /// "최근 완료"에 보이는 기간.
    public static let doneWindow: TimeInterval = 24 * 3_600

    public private(set) var listings: [TicketListing] = []
    public private(set) var query = ""
    public private(set) var selectedId: Int64?
    /// 사용자가 "최근 완료"를 펼쳤는가. 검색 중에는 펼쳐서 보여준다.
    public var doneExpanded = false

    public init() {}

    /// 사용자가 "보관함"을 펼쳤는가. 검색 중에는 펼쳐서 보여준다.
    public var archiveExpanded = false
    /// 무시를 눌렀고 되돌리기 시간이 아직 안 끝난 티켓: 목록, 배지, 선택에서 빠진다(실제 삭제는 시간이 지난 뒤).
    public private(set) var hiddenIds: Set<Int64> = []

    /// 아이콘 배지: 검색어와 상관없이 `waiting` 전체 개수. 보관된 티켓과 방금 무시한 티켓은 세지 않는다.
    public var badgeCount: Int {
        listings.filter { $0.ticket.status == .waiting && $0.ticket.archivedAt == nil && !hiddenIds.contains($0.ticket.id) }.count
    }

    /// 보관함에 있는(무시 대기 중이 아닌) 티켓 수. 검색과 상관없다.
    public var archivedCount: Int {
        listings.filter { $0.ticket.archivedAt != nil && !hiddenIds.contains($0.ticket.id) }.count
    }

    public var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Derived

    public func sections(now: Date) -> [MenuSectionModel] {
        let terms = trimmedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        let cutoff = now.addingTimeInterval(-Self.doneWindow)
        let matching = listings.filter { listing in
            let ticket = listing.ticket
            if hiddenIds.contains(ticket.id) { return false }
            if ticket.status == .done, ticket.archivedAt == nil, ticket.lastActivityAt < cutoff { return false }
            return Self.matches(ticket, terms: terms)
        }
        return MenuSection.allCases.compactMap { section in
            let rows = matching
                .filter { Self.section(of: $0.ticket) == section }
                .sorted { ($0.ticket.lastActivityAt, $0.ticket.id) > ($1.ticket.lastActivityAt, $1.ticket.id) }
                .map(MenuRow.init)
            guard !rows.isEmpty else { return nil }
            let collapsed = !isExpanded(section) && terms.isEmpty
            return MenuSectionModel(section: section, rows: rows, collapsed: collapsed)
        }
    }

    /// 티켓이 가는 섹션: 보관됐으면 상태와 상관없이 보관함. done이 되면 보관은 저장소가 풀므로(`Store.patchTicket`) 정상 경로에서
    /// done+보관이 겹치는 일은 없다.
    static func section(of ticket: Ticket) -> MenuSection {
        ticket.archivedAt != nil ? .archive : MenuSection(ticket.status)
    }

    /// 접을 수 있는 섹션(최근 완료, 보관함)이 펼쳐져 있는가. 나머지 섹션은 늘 펼쳐져 있다.
    public func isExpanded(_ section: MenuSection) -> Bool {
        switch section {
        case .done: doneExpanded
        case .archive: archiveExpanded
        default: true
        }
    }

    /// 화면 위에서 아래 순서의 선택 가능한 행 id.
    public func selectableIds(now: Date) -> [Int64] {
        sections(now: now).flatMap { $0.visibleRows.map(\.id) }
    }

    /// 제목, 프로젝트, next_action에서 찾는다. 검색어의 단어가 모두 (대소문자 무시) 들어 있어야 한다.
    static func matches(_ ticket: Ticket, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = [ticket.title, ticket.project ?? "", ticket.nextAction ?? ""].joined(separator: "\n")
        return terms.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    // MARK: Mutations

    /// 새 목록을 반영한다. 선택은 그 행이 아직 보이면 유지하고, 아니면 맨 위로.
    public mutating func apply(_ listings: [TicketListing], now: Date) {
        self.listings = listings
        // 이미 지워진 티켓의 무시 대기 표시는 필요 없다.
        let present = Set(listings.map(\.ticket.id))
        hiddenIds.formIntersection(present)
        reconcileSelection(now: now)
    }

    /// 무시를 눌렀다: 되돌리기 시간 동안 목록에서 숨긴다(DB는 그대로).
    /// 선택한 행을 숨기면 선택은 그 자리의 다음 행으로(마지막이면 이전 행으로) 간다: 맨 위로 튀지 않아 키보드 흐름이 이어진다.
    public mutating func hide(_ id: Int64, now: Date) {
        let before = selectableIds(now: now)
        hiddenIds.insert(id)
        if selectedId == id, let index = before.firstIndex(of: id) {
            let after = before.filter { $0 != id }
            selectedId = after.indices.contains(index) ? after[index] : after.last
        }
        reconcileSelection(now: now)
    }

    public mutating func unhide(_ id: Int64, now: Date) {
        hiddenIds.remove(id)
        reconcileSelection(now: now)
    }

    public mutating func setQuery(_ text: String, now: Date) {
        guard text != query else { return }
        query = text
        selectedId = nil
        reconcileSelection(now: now)
    }

    /// 방향키. 끝에서는 멈춘다(순환하지 않는다). 선택이 없으면 위 방향은 마지막, 아래 방향은 첫 행.
    public mutating func moveSelection(by delta: Int, now: Date) {
        let ids = selectableIds(now: now)
        guard !ids.isEmpty else { selectedId = nil; return }
        guard let current = selectedId.flatMap(ids.firstIndex(of:)) else {
            selectedId = delta > 0 ? ids.first : ids.last
            return
        }
        selectedId = ids[min(max(current + delta, 0), ids.count - 1)]
    }

    /// 보이는 행만 선택할 수 있다. 접힌 행이나 없는 id는 무시하고 선택을 그대로 둔다. nil은 선택 해제.
    public mutating func select(_ id: Int64?, now: Date) {
        guard let id else { selectedId = nil; return }
        if selectableIds(now: now).contains(id) { selectedId = id }
    }

    /// 섹션 접힘을 바꾸면 선택 가능한 행이 달라지므로 선택을 다시 맞춘다. 접을 수 없는 섹션은 무시한다.
    public mutating func toggle(_ section: MenuSection, now: Date) {
        switch section {
        case .done: doneExpanded.toggle()
        case .archive: archiveExpanded.toggle()
        default: return
        }
        reconcileSelection(now: now)
    }

    public mutating func toggleDone(now: Date) { toggle(.done, now: now) }

    public mutating func reconcileSelection(now: Date) {
        let ids = selectableIds(now: now)
        if let selectedId, ids.contains(selectedId) { return }
        selectedId = ids.first
    }

    public func listing(id: Int64) -> TicketListing? { listings.first { $0.ticket.id == id } }
}
