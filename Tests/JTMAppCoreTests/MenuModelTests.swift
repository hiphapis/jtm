import Foundation
import Testing
@testable import JTMAppCore
@testable import JTMCore

@Suite struct MenuModelTests {
    private let now = epoch.addingTimeInterval(3_600)

    private func state(_ listings: [TicketListing]) -> MenuState {
        var state = MenuState()
        state.apply(listings, now: now)
        return state
    }

    @Test func sectionsFollowTheDocumentedOrderAndSkipEmptyOnes() {
        let s = state([
            listing(makeTicket(1, status: .done, activity: epoch)),
            listing(makeTicket(2, status: .blocked)),
            listing(makeTicket(3, status: .inbox)),
            listing(makeTicket(4, status: .active)),
            listing(makeTicket(5, status: .waiting, reason: .permission)),
        ])
        #expect(s.sections(now: now).map(\.section) == [.waiting, .active, .inbox, .blocked, .done])
        #expect(s.sections(now: now).map(\.section.title) == ["내 입력 대기", "진행 중", "Inbox", "Blocked", "최근 완료"])
        #expect(state([listing(makeTicket(1, status: .inbox))]).sections(now: now).map(\.section) == [.inbox])
    }

    @Test func rowsInASectionAreNewestActivityFirstThenHighestId() {
        let s = state([
            listing(makeTicket(1, activity: epoch)),
            listing(makeTicket(2, activity: epoch.addingTimeInterval(60))),
            listing(makeTicket(3, activity: epoch.addingTimeInterval(60))),
        ])
        #expect(s.sections(now: now)[0].rows.map(\.id) == [3, 2, 1])
    }

    @Test func waitingRowsCarryTheReasonLabel() {
        let reasons: [(WaitingReason?, String?)] = [
            (.permission, "권한"), (.turnEnd, "턴 종료"), (.stale, "멈춤"), (.error, "오류"), (nil, nil),
        ]
        for (reason, label) in reasons {
            let row = state([listing(makeTicket(1, status: .waiting, reason: reason))]).sections(now: now)[0].rows[0]
            #expect(row.reasonLabel == label)
        }
        // 대기가 아닌 티켓에는 이유 표시가 없다.
        #expect(state([listing(makeTicket(1, status: .active, reason: .stale))]).sections(now: now)[0].rows[0].reasonLabel == nil)
    }

    @Test func badgeCountsAllWaitingTicketsRegardlessOfSearch() {
        var s = state([
            listing(makeTicket(1, "alpha", status: .waiting)),
            listing(makeTicket(2, "beta", status: .waiting)),
            listing(makeTicket(3, "gamma", status: .active)),
        ])
        #expect(s.badgeCount == 2)
        s.setQuery("gamma", now: now)
        #expect(s.badgeCount == 2)
        #expect(s.sections(now: now).flatMap(\.rows).map(\.id) == [3])
        #expect(state([]).badgeCount == 0)
    }

    @Test func searchMatchesTitleProjectAndNextActionCaseInsensitivelyWithAllTerms() {
        var s = state([
            listing(makeTicket(1, "Fix Login Bug", project: "webapp")),
            listing(makeTicket(2, "other", project: "Billing", next: "email the vendor")),
            listing(makeTicket(3, "로그인 오류 수정", project: "앱")),
        ])
        func ids(_ query: String) -> [Int64] {
            s.setQuery(query, now: now)
            return s.sections(now: now).flatMap(\.rows).map(\.id).sorted()
        }
        #expect(ids("login") == [1])
        #expect(ids("BILLING") == [2])
        #expect(ids("vendor") == [2])
        #expect(ids("login webapp") == [1])
        #expect(ids("login billing") == [])
        #expect(ids("로그인") == [3])
        #expect(ids("   ") == [1, 2, 3])
    }

    @Test func doneShowsOnlyTheLast24HoursAndStartsCollapsed() {
        let recent = now.addingTimeInterval(-3_600)
        let old = now.addingTimeInterval(-MenuState.doneWindow - 60)
        var s = state([
            listing(makeTicket(1, status: .done, activity: recent)),
            listing(makeTicket(2, status: .done, activity: old)),
        ])
        let done = s.sections(now: now)[0]
        #expect(done.section == .done && done.collapsed && done.rows.map(\.id) == [1] && done.visibleRows.isEmpty)
        #expect(s.selectableIds(now: now).isEmpty)
        s.toggleDone(now: now)
        #expect(s.sections(now: now)[0].visibleRows.map(\.id) == [1])
        #expect(s.selectableIds(now: now) == [1])
    }

    @Test func searchExpandsTheDoneSection() {
        var s = state([listing(makeTicket(1, "shipped", status: .done, activity: now))])
        s.setQuery("ship", now: now)
        #expect(s.sections(now: now)[0].collapsed == false)
        #expect(s.selectedId == 1)
    }

    @Test func rowUsesThePrimaryLocationAsDestination() {
        let ticket = makeTicket(1)
        let s = state([listing(ticket, [
            makeLocation(1, ticket: 1, .url(.init(url: "https://a.example")), seen: epoch.addingTimeInterval(100)),
            makeLocation(2, ticket: 1, .orcaTerminal(.init(terminalHandle: "t")), seen: epoch),
        ])])
        #expect(s.sections(now: now)[0].rows[0].destination == .orcaTerminal)  // orca_terminal 우선 (Resolver.choose)
        #expect(state([listing(ticket)]).sections(now: now)[0].rows[0].destination == nil)
        for kind in LocationKind.allCases { #expect(!kind.symbolName.isEmpty) }
    }

    @Test func rowHidesEmptyProjectAndNextAction() {
        let row = state([listing(makeTicket(1, project: "", next: ""))]).sections(now: now)[0].rows[0]
        #expect(row.project == nil && row.nextAction == nil)
    }

    // MARK: Selection

    @Test func selectionStartsOnTheFirstVisibleRowAndArrowsStopAtTheEnds() {
        var s = state([
            listing(makeTicket(1, status: .waiting)),
            listing(makeTicket(2, status: .active)),
            listing(makeTicket(3, status: .inbox)),
        ])
        #expect(s.selectedId == 1)
        s.moveSelection(by: -1, now: now)
        #expect(s.selectedId == 1)
        s.moveSelection(by: 1, now: now)
        s.moveSelection(by: 1, now: now)
        #expect(s.selectedId == 3)
        s.moveSelection(by: 1, now: now)
        #expect(s.selectedId == 3)
        s.moveSelection(by: -1, now: now)
        #expect(s.selectedId == 2)
    }

    @Test func selectionSurvivesReloadsWhileTheRowExistsAndFallsBackToTheTop() {
        var s = state([listing(makeTicket(1, status: .waiting)), listing(makeTicket(2, status: .active))])
        s.select(2, now: now)
        s.apply([listing(makeTicket(2, status: .active)), listing(makeTicket(1, status: .waiting)), listing(makeTicket(9, status: .inbox))], now: now)
        #expect(s.selectedId == 2)
        s.apply([listing(makeTicket(9, status: .inbox))], now: now)
        #expect(s.selectedId == 9)
        s.apply([], now: now)
        #expect(s.selectedId == nil)
    }

    @Test func changingTheQueryResetsTheSelectionToTheFirstMatch() {
        var s = state([listing(makeTicket(1, "aa")), listing(makeTicket(2, "bb"))])
        s.select(1, now: now)
        s.setQuery("bb", now: now)
        #expect(s.selectedId == 2)
        s.setQuery("zz", now: now)
        #expect(s.selectedId == nil)
        s.moveSelection(by: 1, now: now)
        #expect(s.selectedId == nil)
    }

    @Test func arrowFromNoSelectionPicksTheEndInThatDirection() {
        var s = state([listing(makeTicket(1)), listing(makeTicket(2))])
        s.select(nil, now: now)
        s.moveSelection(by: -1, now: now)
        #expect(s.selectedId == 1 || s.selectedId == 2)
        s.select(nil, now: now)
        s.moveSelection(by: 1, now: now)
        #expect(s.selectedId == s.selectableIds(now: now).first)
    }

    @Test func collapsedDoneRowsCannotBeSelectedOrSteppedInto() {
        var s = state([
            listing(makeTicket(1, status: .active)),
            listing(makeTicket(2, status: .done, activity: now)),
        ])
        s.select(2, now: now)
        #expect(s.selectedId == 1)
        s.moveSelection(by: 1, now: now)
        #expect(s.selectedId == 1)
    }

    // MARK: Relative time

    @Test func koreanRelativeTime() {
        func ago(_ seconds: TimeInterval) -> String { RelativeTimeKo.string(from: epoch, now: epoch.addingTimeInterval(seconds)) }
        #expect(ago(0) == "방금")
        #expect(ago(59) == "방금")
        #expect(ago(60) == "1분 전")
        #expect(ago(3_599) == "59분 전")
        #expect(ago(3_600) == "1시간 전")
        #expect(ago(86_399) == "23시간 전")
        #expect(ago(86_400 * 3) == "3일 전")
        #expect(ago(-30) == "방금")  // 시계가 어긋나도 음수 표시는 없다
    }
}

@Suite struct ArchiveModelTests {
    private let now = epoch.addingTimeInterval(3_600)

    private func state(_ listings: [TicketListing]) -> MenuState {
        var state = MenuState()
        state.apply(listings, now: now)
        return state
    }

    @Test func archiveIsTheLastCollapsedSectionAndCountsInItsHeader() {
        let s = state([
            listing(makeTicket(1, status: .active)),
            listing(makeTicket(2, status: .blocked, archivedAt: epoch)),
            listing(makeTicket(3, status: .waiting, archivedAt: epoch)),
        ])
        let sections = s.sections(now: now)
        #expect(sections.map(\.section) == [.active, .archive])
        #expect(MenuSection.allCases.last == .archive && MenuSection.archive.title == "보관함")
        #expect(sections[1].rows.count == 2 && sections[1].collapsed && s.archivedCount == 2)
        // 보관된 행은 원래 상태의 섹션에 나타나지 않는다.
        let outsideArchive = sections.filter { $0.section != .archive }.flatMap(\.rows).map(\.id)
        #expect(outsideArchive == [1])
        let archivedFlags = sections[1].rows.map { $0.archived }
        #expect(archivedFlags == [true, true])
    }

    @Test func searchOpensTheArchiveAndFindsArchivedTickets() {
        var s = state([listing(makeTicket(1, "alpha", archivedAt: epoch)), listing(makeTicket(2, "beta"))])
        s.setQuery("alpha", now: now)
        let sections = s.sections(now: now)
        #expect(sections.map(\.section) == [.archive] && !sections[0].collapsed)
        #expect(s.selectedId == 1)
    }

    @Test func archivedRowsAreSelectableOnlyWhileTheSectionIsExpanded() {
        var s = state([listing(makeTicket(1)), listing(makeTicket(2, archivedAt: epoch))])
        #expect(s.selectableIds(now: now) == [1])
        s.toggle(.archive, now: now)
        #expect(s.archiveExpanded && s.selectableIds(now: now) == [1, 2])
        s.select(2, now: now)
        s.toggle(.archive, now: now)  // 접으면 선택이 보이는 행으로 돌아온다
        #expect(s.selectedId == 1)
        s.toggle(.waiting, now: now)  // 접을 수 없는 섹션은 무시한다
        #expect(!s.doneExpanded && !s.archiveExpanded)
    }

    @Test func doneAndArchiveFoldIndependently() {
        var s = state([listing(makeTicket(1, status: .done, activity: now)), listing(makeTicket(2, archivedAt: epoch))])
        s.toggle(.done, now: now)
        let sections = s.sections(now: now)
        #expect(sections.first { $0.section == .done }?.collapsed == false)
        #expect(sections.first { $0.section == .archive }?.collapsed == true)
        s.toggleDone(now: now)
        #expect(!s.doneExpanded)
    }

    @Test func aDoneTicketThatIsArchivedStaysInTheArchiveEvenPastTheDoneWindow() {
        let s = state([listing(makeTicket(1, status: .done, activity: epoch.addingTimeInterval(-10 * 86_400), archivedAt: epoch))])
        #expect(s.sections(now: now).map(\.section) == [.archive])
    }

    @Test func badgeSkipsArchivedAndHiddenTickets() {
        var s = state([
            listing(makeTicket(1, status: .waiting)),
            listing(makeTicket(2, status: .waiting, archivedAt: epoch)),
            listing(makeTicket(3, status: .waiting)),
        ])
        #expect(s.badgeCount == 2)
        s.hide(3, now: now)
        #expect(s.badgeCount == 1 && s.hiddenIds == [3])
        #expect(s.sections(now: now).flatMap(\.rows).map(\.id).contains(3) == false)
        s.unhide(3, now: now)
        #expect(s.badgeCount == 2)
    }

    @Test func hiddenIdsDisappearOnceTheTicketIsGone() {
        var s = state([listing(makeTicket(1)), listing(makeTicket(2))])
        s.hide(1, now: now)
        s.apply([listing(makeTicket(2))], now: now)
        #expect(s.hiddenIds.isEmpty)
    }

    @Test func hidingTheSelectedRowMovesTheSelection() {
        var s = state([listing(makeTicket(1, activity: epoch.addingTimeInterval(60))), listing(makeTicket(2))])
        #expect(s.selectedId == 1)
        s.hide(1, now: now)
        #expect(s.selectedId == 2)
    }
}
