import AppKit
import Foundation
import Testing
@testable import JTMAppCore
@testable import JTMCore

@Suite(.korean) struct RowHelpTests {
    @Test func everyDestinationKindHasATooltipThatSaysWhatClickingDoes() {
        for kind in LocationKind.allCases {
            #expect(kind.helpText.contains("—") && kind.helpText.hasPrefix(kind.displayName), "\(kind)")
            #expect(kind.clickEffect.hasPrefix("클릭하면"), "\(kind)")
        }
        #expect(LocationKind.orcaTerminal.helpText == "Orca 터미널 — 클릭하면 이 터미널로 이동")
    }

    @Test func rowsCarryTheirDestinationAndReasonTooltips() {
        func row(_ ticket: Ticket, _ locations: [Location] = []) -> MenuRow { MenuRow(listing(ticket, locations)) }
        let terminal = makeLocation(1, ticket: 1, .orcaTerminal(.init(terminalHandle: "h", tabId: "t")))
        let waiting = row(makeTicket(1, status: .waiting, reason: .permission), [terminal])
        #expect(waiting.destinationHelp == "Orca 터미널 — 클릭하면 이 터미널로 이동")
        #expect(waiting.reasonHelp?.hasPrefix("입력 대기: 권한 요청") == true)
        #expect(waiting.reasonLabel == "권한")
        // 이유가 없으면 툴팁도 없고, 위치가 없으면 그렇게 알려 준다.
        let active = row(makeTicket(2, status: .active, reason: .stale))
        #expect(active.reasonHelp == nil && active.destinationHelp == LocationKind.noDestinationHelp)
    }

    @Test func everyWaitingReasonExplainsItself() {
        for reason in WaitingReason.allCases {
            #expect(reason.helpText.hasPrefix("입력 대기: \(reason.displayName)"), "\(reason)")
            #expect(!reason.meaning.isEmpty)
        }
    }

    @Test func rowsShowFourButtonsOrOnlyRestoreInTheArchive() {
        let normal = MenuRow(listing(makeTicket(1)))
        #expect(normal.actions == [.keep, .editNextAction, .done, .ignore] && !normal.archived)
        let archived = MenuRow(listing(makeTicket(2, archivedAt: epoch)))
        #expect(archived.actions == [.restore] && archived.archived)
        #expect(MenuRow(listing(makeTicket(3, kept: true))).kept)
    }

    @Test func buttonSymbolsAndTooltips() {
        #expect(RowAction.keep.symbolName(kept: false) == "star" && RowAction.keep.symbolName(kept: true) == "star.fill")
        #expect(RowAction.rowActions == [.keep, .editNextAction, .done, .ignore])
        for action in RowAction.allCases {
            #expect(!action.help().isEmpty && !action.label.isEmpty, "\(action)")
        }
        #expect(RowAction.keep.help(kept: true) != RowAction.keep.help(kept: false))
        #expect(RowAction.done.help().contains("⌘D") && RowAction.editNextAction.help().contains("⌘E"))
        #expect(RowAction.ignore.help().contains("5초"))
    }

    @Test func everyButtonHasAShortcutAndTheTooltipSaysIt() {
        #expect(RowAction.keep.shortcut == "⌘S" && RowAction.ignore.shortcut == "⌘⌫" && RowAction.restore.shortcut == "⌘R")
        for action in RowAction.allCases {
            #expect(action.help(kept: false).contains(action.shortcut), "\(action)")
            #expect(action.help(kept: true).contains(action.shortcut), "\(action)")
        }
    }

    @Test func voiceOverReadsTheKeepStateAsAValueAndEveryButtonHasALabel() {
        for action in RowAction.allCases {
            #expect(!action.accessibilityLabel.isEmpty, "\(action)")
            if action != .keep { #expect(action.accessibilityValue(kept: true) == nil, "\(action)") }
        }
        #expect(RowAction.keep.accessibilityLabel == "유지")
        #expect(RowAction.keep.accessibilityValue(kept: true) == "켜짐" && RowAction.keep.accessibilityValue(kept: false) == "꺼짐")
        #expect(RowAction.ignoreConfirmLabel == "정말 지울까요?")
    }

    @Test func theRowReadsAsOneSentenceForVoiceOver() {
        let terminal = makeLocation(1, ticket: 1, .orcaTerminal(.init(terminalHandle: "h", tabId: "t")))
        let ticket = makeTicket(1, "Fix login", status: .waiting, reason: .permission, project: "web", next: "approve", kept: true)
        let label = MenuRow(listing(ticket, [terminal])).accessibilityLabel(now: epoch.addingTimeInterval(300))
        #expect(label == "Fix login, 프로젝트 web, 입력 대기, 권한 요청, Orca 터미널, 5분 전, next_action approve, 유지함")
        let archived = MenuRow(listing(makeTicket(2, "Old", archivedAt: epoch))).accessibilityLabel(now: epoch)
        #expect(archived == "Old, 보관함, 이동할 위치 없음, 방금")
    }

    @Test func rowsKnowWhetherADeleteNeedsAConfirmation() {
        var noted = makeTicket(4); noted.note = "x"
        #expect(!MenuRow(listing(makeTicket(1))).needsIgnoreConfirmation)
        #expect(MenuRow(listing(makeTicket(2, kept: true))).needsIgnoreConfirmation)
        #expect(MenuRow(listing(makeTicket(3, next: "go"))).needsIgnoreConfirmation)
        #expect(MenuRow(listing(noted)).needsIgnoreConfirmation)
        #expect(!MenuRow(listing(makeTicket(5, next: ""))).needsIgnoreConfirmation)
    }

    @Test func everySFSymbolUsedByTheRowsAndTheLegendExists() {
        var names = Set(LocationKind.allCases.map(\.symbolName))
        for action in RowAction.allCases { names.formUnion([action.symbolName(kept: false), action.symbolName(kept: true)]) }
        names.formUnion(["questionmark.circle", "chevron.right", "chevron.down", "xmark"])
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }

    // MARK: 범례

    @Test func theLegendListsEveryDestinationStatusReasonAndButton() {
        let destinationIds = Legend.destinations.map(\.id)
        #expect(destinationIds == LocationKind.allCases.map { "dest-\($0.rawValue)" })
        #expect(Legend.destinations.allSatisfy { $0.symbol != nil && !$0.detail.isEmpty })

        let statusIds = Set(Legend.statuses.map(\.id))
        for status in TicketStatus.allCases { #expect(statusIds.contains("status-\(status.rawValue)"), "\(status)") }
        for reason in WaitingReason.allCases { #expect(statusIds.contains("reason-\(reason.rawValue)"), "\(reason)") }
        #expect(statusIds.contains("status-archive"))
        // 이유는 "내 입력 대기" 바로 아래에 붙는다.
        let ids = Legend.statuses.map(\.id)
        let waiting = ids.firstIndex(of: "status-waiting") ?? -1
        #expect(ids[(waiting + 1)...(waiting + WaitingReason.allCases.count)].allSatisfy { $0.hasPrefix("reason-") })

        #expect(Legend.actions.count == RowAction.allCases.count && Legend.actions.allSatisfy { $0.symbol != nil })
        let all = Legend.destinations + Legend.statuses + Legend.actions
        #expect(Set(all.map(\.id)).count == all.count)  // id가 겹치지 않는다
    }

    @Test func theLegendReusesTheTooltipText() {
        let orca = Legend.destinations.first { $0.id == "dest-orca_terminal" }
        #expect(orca?.detail == LocationKind.orcaTerminal.clickEffect)
        let permission = Legend.statuses.first { $0.id == "reason-permission" }
        #expect(permission?.detail == WaitingReason.permission.meaning)
    }
}
