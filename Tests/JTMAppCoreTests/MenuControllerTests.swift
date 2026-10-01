import Foundation
import Observation
import Testing
@testable import JTMAppCore
@testable import JTMCore

/// 호출을 기록하고 정해 둔 결과를 돌려주는 가짜 백엔드.
private final class FakeBackend: MenuBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _listings: [TicketListing] = []
    private var _calls: [String] = []
    private var _goResult = GoOutcome(ok: true, message: "switched")
    private var _writeError: (any Error)?
    var loadDelay: Duration = .zero

    var listings: [TicketListing] { get { lock.withLock { _listings } } set { lock.withLock { _listings = newValue } } }
    var calls: [String] { lock.withLock { _calls } }
    var goResult: GoOutcome { get { lock.withLock { _goResult } } set { lock.withLock { _goResult = newValue } } }
    var writeError: (any Error)? { get { lock.withLock { _writeError } } set { lock.withLock { _writeError = newValue } } }
    private func log(_ call: String) { lock.withLock { _calls.append(call) } }

    func load(now: Date) async throws -> [TicketListing] {
        log("load")
        if loadDelay > .zero { try await Task.sleep(for: loadDelay) }
        return listings
    }
    func setStatus(id: Int64, _ status: TicketStatus) async throws {
        log("status \(id) \(status.rawValue)")
        if let writeError { throw writeError }
    }
    func setNextAction(id: Int64, _ text: String?) async throws { log("next \(id) \(text ?? "nil")") }
    func setTitle(id: Int64, _ title: String) async throws { log("title \(id) \(title)") }
    func go(id: Int64) async -> GoOutcome { log("go \(id)"); return goResult }
    func setKept(id: Int64, _ kept: Bool) async throws {
        log("kept \(id) \(kept)")
        if let writeError { throw writeError }
    }
    func ignore(id: Int64) async throws {
        log("ignore \(id)")
        if let writeError { throw writeError }
    }
    func restore(id: Int64) async throws { log("restore \(id)") }
    func archiveStale(now: Date) async throws -> Int { log("archive"); return archivedCount }
    var archivedCount: Int { get { lock.withLock { _archivedCount } } set { lock.withLock { _archivedCount = newValue } } }
    private var _archivedCount = 0
}

private struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }

@MainActor
private func makeController(
    _ backend: FakeBackend, sync: @escaping @Sendable (SyncTrigger) async -> SyncOutcome? = { _ in nil }
) -> MenuController {
    MenuController(backend: backend, sync: sync, clock: { epoch.addingTimeInterval(60) })
}

@MainActor @Suite struct MenuControllerTests {
    @Test func reloadFillsTheStateAndTheBadge() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1, status: .waiting)), listing(makeTicket(2, status: .waiting)), listing(makeTicket(3))]
        let controller = makeController(backend)
        await controller.reload()
        #expect(controller.badgeCount == 2)
        #expect(controller.sections.map(\.section) == [.waiting, .active])
        #expect(controller.state.selectedId == 1 || controller.state.selectedId == 2)
    }

    @Test func reloadingAnUnchangedListInvalidatesNothing() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1, status: .waiting))]
        let controller = makeController(backend)
        await controller.reload()
        let invalidations = Counter()
        withObservationTracking {
            _ = controller.state
            _ = controller.now
            _ = controller.loadError
        } onChange: { invalidations.increment() }
        await controller.reload()
        #expect(invalidations.value == 0)
        backend.listings = [listing(makeTicket(1, status: .active))]
        await controller.reload()
        #expect(invalidations.value == 1)  // 목록이 바뀌면 무효화된다
    }

    @Test func aFailedReloadKeepsTheOldListAndReportsTheError() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1))]
        let controller = makeController(backend)
        await controller.reload()
        struct Failing: MenuBackend {
            func load(now: Date) async throws -> [TicketListing] { throw Boom() }
            func setStatus(id: Int64, _ status: TicketStatus) async throws {}
            func setNextAction(id: Int64, _ text: String?) async throws {}
            func setTitle(id: Int64, _ title: String) async throws {}
            func go(id: Int64) async -> GoOutcome { GoOutcome(ok: false, message: "") }
        }
        let failing = MenuController(backend: Failing(), clock: { epoch })
        await failing.reload()
        #expect(failing.loadError == "boom" && failing.badgeCount == 0)
        #expect(controller.loadError == nil && controller.state.listings.count == 1)
    }

    @Test func overlappingReloadsAreCoalescedIntoOneMoreRead() async {
        let backend = FakeBackend()
        backend.loadDelay = .milliseconds(80)
        let controller = makeController(backend)
        async let first: Void = controller.reload()
        try? await Task.sleep(for: .milliseconds(20))
        await controller.reload()  // 진행 중이라 바로 돌아오고 다시 읽기만 예약한다
        await first
        #expect(backend.calls.filter { $0 == "load" }.count == 2)
    }

    // MARK: Go

    @Test func aSuccessfulGoClosesThePopover() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(7))]
        let controller = makeController(backend)
        await controller.reload()
        var closed = 0
        controller.closePopover = { closed += 1 }
        controller.popoverOpened()  // 행을 누를 수 있는 것은 팝오버가 열려 있을 때뿐이다
        await controller.activateSelected()
        #expect(backend.calls.contains("go 7") && closed == 1 && controller.feedback == nil)
    }

    @Test func aClipboardFallbackKeepsThePopoverOpenWithAMessage() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(7))]
        backend.goResult = GoOutcome(ok: true, message: "orca switch failed; copied resume command", copiedToClipboard: true)
        let controller = makeController(backend)
        await controller.reload()
        var closed = 0
        controller.closePopover = { closed += 1 }
        controller.popoverOpened()
        await controller.activate(7)
        #expect(closed == 0)
        #expect(controller.feedback == Feedback(ticketId: 7, message: "재개 명령을 클립보드에 복사했어요", isError: false))
    }

    @Test func aFailedGoKeepsThePopoverOpenAndShowsTheReason() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(7))]
        backend.goResult = GoOutcome(ok: false, message: "orca switch failed (timeout)")
        let controller = makeController(backend)
        await controller.reload()
        var closed = 0
        controller.closePopover = { closed += 1 }
        controller.popoverOpened()
        await controller.activate(7)
        #expect(closed == 0)
        let feedback = controller.feedback
        #expect(feedback?.ticketId == 7 && feedback?.isError == true)
        #expect(feedback?.message.contains("orca switch failed (timeout)") == true)
    }

    // MARK: Go while the popover is closed / reopened (S1)

    /// 이동이 오래 걸리는 백엔드: `release()`를 부를 때까지 `go`가 끝나지 않는다.
    private final class SlowGoBackend: MenuBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<GoOutcome, Never>?
        private var started = false
        var hasStarted: Bool { lock.withLock { started } }
        func load(now: Date) async throws -> [TicketListing] { [listing(makeTicket(1, status: .waiting))] }
        func setStatus(id: Int64, _ status: TicketStatus) async throws {}
        func setNextAction(id: Int64, _ text: String?) async throws {}
        func setTitle(id: Int64, _ title: String) async throws {}
        func go(id: Int64) async -> GoOutcome {
            await withCheckedContinuation { continuation in
                lock.withLock { self.continuation = continuation; started = true }
            }
        }
        func release(_ outcome: GoOutcome) { lock.withLock { continuation?.resume(returning: outcome); continuation = nil } }
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aFailureAfterThePopoverClosedReopensItWithTheMessage() async {
        let backend = SlowGoBackend()
        let controller = MenuController(backend: backend, clock: { epoch.addingTimeInterval(60) })
        await controller.reload()
        var presented = 0
        controller.presentPopover = { presented += 1; controller.popoverOpened(); return true }
        controller.popoverOpened()
        let go = Task { await controller.activate(1) }
        await waitUntil(backend.hasStarted)
        controller.popoverClosed()  // Orca가 앞으로 나오면서 팝오버가 닫혔다
        backend.release(GoOutcome(ok: false, message: "no such tab"))
        await go.value
        #expect(presented == 1)
        #expect(controller.isOpen)
        #expect(controller.feedback?.isError == true && controller.feedback?.message.contains("no such tab") == true)
    }

    @Test func aClipboardFallbackAfterThePopoverClosedReopensItToo() async {
        let backend = SlowGoBackend()
        let controller = MenuController(backend: backend, clock: { epoch.addingTimeInterval(60) })
        await controller.reload()
        controller.presentPopover = { controller.popoverOpened(); return true }
        controller.popoverOpened()
        let go = Task { await controller.activate(1) }
        await waitUntil(backend.hasStarted)
        controller.popoverClosed()
        backend.release(GoOutcome(ok: true, message: "copied", copiedToClipboard: true))
        await go.value
        #expect(controller.isOpen && controller.feedback?.message == "재개 명령을 클립보드에 복사했어요")
    }

    @Test func aSuccessWhileThePopoverIsStillOpenClosesIt() async {
        let backend = SlowGoBackend()
        let controller = MenuController(backend: backend, clock: { epoch.addingTimeInterval(60) })
        await controller.reload()
        var closed = 0
        controller.closePopover = { closed += 1 }
        controller.popoverOpened()
        let go = Task { await controller.activate(1) }
        await waitUntil(backend.hasStarted)
        backend.release(GoOutcome(ok: true, message: "switched"))
        await go.value
        #expect(closed == 1)
    }

    @Test func aLateSuccessDoesNotCloseAPopoverTheUserOpenedInTheMeantime() async {
        let backend = SlowGoBackend()
        let controller = MenuController(backend: backend, clock: { epoch.addingTimeInterval(60) })
        await controller.reload()
        var closed = 0
        controller.closePopover = { closed += 1 }
        controller.popoverOpened()
        let go = Task { await controller.activate(1) }
        await waitUntil(backend.hasStarted)
        controller.popoverClosed()
        controller.popoverOpened()  // 사용자가 다시 열었다: 새 세대
        backend.release(GoOutcome(ok: true, message: "switched"))
        await go.value
        #expect(closed == 0 && controller.isOpen)
    }

    @Test func aFailureThatCannotBeShownLeavesNoStaleMessageForTheNextOpen() async {
        let backend = SlowGoBackend()
        let controller = MenuController(backend: backend, clock: { epoch.addingTimeInterval(60) })
        await controller.reload()
        controller.presentPopover = { false }  // 앵커도 패널도 없다
        controller.popoverOpened()
        let go = Task { await controller.activate(1) }
        await waitUntil(backend.hasStarted)
        controller.popoverClosed()
        backend.release(GoOutcome(ok: false, message: "boom"))
        await go.value
        controller.popoverOpened()
        #expect(controller.feedback == nil)
    }

    @Test func openingThePopoverClearsAStaleMessage() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1))]
        backend.goResult = GoOutcome(ok: false, message: "old failure")
        let controller = makeController(backend)
        await controller.reload()
        controller.popoverOpened()
        await controller.activate(1)
        #expect(controller.feedback != nil)
        controller.popoverOpened()  // 닫힘 알림 없이 다시 열렸다
        #expect(controller.feedback == nil)
    }

    @Test func aDoneTicketsMessageExpandsTheCollapsedDoneSection() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1, status: .done))]
        backend.goResult = GoOutcome(ok: false, message: "x")
        let controller = makeController(backend)
        await controller.reload()
        controller.popoverOpened()
        await controller.activate(1)
        #expect(controller.state.doneExpanded)
    }

    @Test func goWithNothingSelectedDoesNothing() async {
        let backend = FakeBackend()
        let controller = makeController(backend)
        await controller.activateSelected()
        #expect(backend.calls.isEmpty)
    }

    // MARK: Ticket actions

    @Test func doneAndStatusChangesGoThroughTheBackendAndReload() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1)), listing(makeTicket(2))]
        let controller = makeController(backend)
        await controller.reload()
        await controller.markDoneSelected()
        await controller.setStatus(2, .blocked)
        let selected = controller.state.selectedId
        #expect(selected != nil)
        #expect(backend.calls.filter { $0.hasPrefix("status") }.count == 2)
        #expect(backend.calls.contains("status 2 blocked"))
        #expect(backend.calls.filter { $0 == "load" }.count == 3)
    }

    @Test func aFailedWriteShowsAnInlineError() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1))]
        backend.writeError = Boom()
        let controller = makeController(backend)
        await controller.reload()
        await controller.setStatus(1, .done)
        #expect(controller.feedback?.isError == true && controller.feedback?.message.contains("boom") == true)
    }

    @Test func nextActionEditingPrefillsCommitsAndCancels() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1, next: "old"))]
        let controller = makeController(backend)
        await controller.reload()
        controller.beginEdit(.nextAction)
        #expect(controller.editing == EditSession(ticketId: 1, field: .nextAction, draft: "old"))
        controller.editing?.draft = "new"
        await controller.commitEdit()
        #expect(controller.editing == nil && backend.calls.contains("next 1 new"))

        controller.beginEdit(.nextAction)
        controller.cancelEdit()
        await controller.commitEdit()
        #expect(backend.calls.filter { $0.hasPrefix("next") }.count == 1)
    }

    @Test func titleEditingPrefillsAndIgnoresABlankTitle() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1, "auto title"))]
        let controller = makeController(backend)
        await controller.reload()
        controller.beginEdit(.title)
        #expect(controller.editing?.draft == "auto title")
        controller.editing?.draft = "  "
        await controller.commitEdit()
        #expect(!backend.calls.contains { $0.hasPrefix("title") })
        controller.beginEdit(.title)
        controller.editing?.draft = "My title"
        await controller.commitEdit()
        #expect(backend.calls.contains("title 1 My title"))
    }

    @Test func movingTheSelectionEndsAnEditOnAnotherRow() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1)), listing(makeTicket(2))]
        let controller = makeController(backend)
        await controller.reload()
        controller.beginEdit(.nextAction)
        controller.moveSelection(by: 1)
        #expect(controller.editing == nil)
    }

    // MARK: Popover

    @Test func openingThePopoverFocusesSearchReloadsAndSyncsOnce() async throws {
        let backend = FakeBackend()
        let triggers = Counter()
        let controller = makeController(backend, sync: { trigger in
            if trigger == .open { triggers.increment() }
            return .orcaUnavailable
        })
        let token = controller.focusToken
        controller.popoverOpened()
        #expect(controller.isOpen && controller.focusToken == token + 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(triggers.value == 1 && backend.calls.contains("load"))
        #expect(controller.footerNotice == "Orca 연결 안 됨")
    }

    @Test func closingThePopoverClearsSearchEditingAndMessages() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1, "alpha")), listing(makeTicket(2, "beta"))]
        let controller = makeController(backend)
        await controller.reload()
        controller.setQuery("beta")
        controller.beginEdit(.nextAction)
        controller.popoverClosed()
        #expect(controller.state.query.isEmpty && controller.editing == nil && controller.feedback == nil && !controller.isOpen)
    }

    @Test func aSuccessfulSyncReloadsTheList() async {
        let backend = FakeBackend()
        let controller = makeController(backend, sync: { _ in .synced(SyncSummary()) })
        await controller.runSync(.manual)
        #expect(backend.calls == ["load"] && controller.footerNotice == nil)
    }

    @Test func aManualSyncWhileOneIsRunningShowsSyncingInTheFooter() async {
        let backend = FakeBackend()
        let controller = makeController(backend, sync: { _ in .busy })
        await controller.runSync(.manual)
        #expect(controller.footerNotice == "동기화 중…")
        #expect(backend.calls.isEmpty)
    }

    @Test func aSkippedSyncChangesNothing() async {
        let backend = FakeBackend()
        let controller = makeController(backend, sync: { _ in nil })
        await controller.runSync(.open)
        #expect(backend.calls.isEmpty && controller.syncOutcome == nil)
    }
}

// MARK: 행 버튼, 무시 되돌리기, 보관함

/// 시간을 직접 흘리는 대기: `release()`를 부르면 기다리던 모든 sleep이 끝난다.
private final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    var waiting: Int { lock.withLock { waiters.count } }
    func sleep(_ duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if released { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
        try Task.checkCancellation()
    }
    func release() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { waiters = [] }
            return waiters
        }
        all.forEach { $0.resume() }
    }
}

@MainActor
private func makeIgnoreController(_ backend: FakeBackend, gate: SleepGate) -> MenuController {
    MenuController(backend: backend, clock: { epoch.addingTimeInterval(60) }, sleep: { try await gate.sleep($0) })
}

@MainActor @Suite struct RowButtonControllerTests {
    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func theKeepButtonTogglesThroughTheBackend() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1)), listing(makeTicket(2, kept: true))]
        let controller = makeController(backend)
        await controller.reload()
        await controller.toggleKeep(1)
        await controller.toggleKeep(2)
        #expect(backend.calls.contains("kept 1 true") && backend.calls.contains("kept 2 false"))
        await controller.toggleKeep(99)  // 없는 티켓은 아무것도 하지 않는다
        #expect(!backend.calls.contains { $0.hasPrefix("kept 99") })
    }

    @Test func theDoneButtonMarksTheRowDoneAndTheEditButtonOpensTheInlineEditor() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1, next: "old")), listing(makeTicket(2))]
        let controller = makeController(backend)
        await controller.reload()
        await controller.markDone(2)
        #expect(backend.calls.contains("status 2 done"))
        controller.beginEdit(.nextAction, id: 2)
        #expect(controller.editing == EditSession(ticketId: 2, field: .nextAction, draft: ""))
        #expect(controller.state.selectedId == 2)
    }

    @Test func restoreGoesThroughTheBackend() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1, archivedAt: epoch))]
        let controller = makeController(backend)
        await controller.reload()
        await controller.restore(1)
        #expect(backend.calls.contains("restore 1"))
    }

    @Test func aFailedKeepShowsAnInlineError() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1))]
        backend.writeError = Boom()
        let controller = makeController(backend)
        await controller.reload()
        await controller.toggleKeep(1)
        #expect(controller.feedback?.isError == true)
    }

    // MARK: 무시와 5초 되돌리기

    @Test func ignoreHidesTheRowAtOnceButOnlyIgnoresAfterTheUndoWindow() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1, "a", status: .waiting)), listing(makeTicket(2, "b"))]
        let gate = SleepGate()
        let controller = makeIgnoreController(backend, gate: gate)
        await controller.reload()
        #expect(controller.badgeCount == 1)

        controller.ignore(1)
        #expect(controller.sections.flatMap(\.rows).map(\.id) == [2])  // 바로 사라진다
        #expect(controller.badgeCount == 0)  // 배지에서도 빠진다
        #expect(controller.undoNotice == PendingIgnore(ticketId: 1, title: "a"))
        #expect(controller.state.selectedId == 2)
        #expect(!backend.calls.contains("ignore 1"))  // DB는 그대로다

        backend.listings = [listing(makeTicket(2, "b"))]  // 확정되면 DB에서 사라진다
        gate.release()
        await waitUntil(backend.calls.contains("ignore 1"))
        await waitUntil(controller.pendingIgnores.isEmpty)
        #expect(backend.calls.contains("ignore 1") && controller.undoNotice == nil)
        await waitUntil(controller.state.hiddenIds.isEmpty)  // 숨김은 확정 뒤의 다시 읽기에서 풀린다(그 읽기가 끝날 때까지 기다린다)
        #expect(controller.state.hiddenIds.isEmpty)
    }

    @Test func undoWithinTheWindowRestoresTheRowWithoutTouchingTheDatabase() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1, "a", status: .waiting)), listing(makeTicket(2, "b"))]
        let gate = SleepGate()
        let controller = makeIgnoreController(backend, gate: gate)
        await controller.reload()
        controller.ignore(1)
        await waitUntil(gate.waiting == 1)
        controller.undoIgnore()
        #expect(controller.sections.flatMap(\.rows).map(\.id).sorted() == [1, 2])
        #expect(controller.badgeCount == 1 && controller.undoNotice == nil && controller.state.selectedId == 1)
        gate.release()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!backend.calls.contains { $0.hasPrefix("ignore") })  // 취소된 타이머는 아무것도 하지 않는다
    }

    @Test func undoOnlyTakesBackTheMostRecentIgnore() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1)), listing(makeTicket(2)), listing(makeTicket(3))]
        let gate = SleepGate()
        let controller = makeIgnoreController(backend, gate: gate)
        await controller.reload()
        controller.ignore(1)
        controller.ignore(2)
        #expect(controller.pendingIgnores.map(\.ticketId) == [1, 2] && controller.undoNotice?.ticketId == 2)
        controller.undoIgnore()
        #expect(controller.sections.flatMap(\.rows).map(\.id).sorted() == [2, 3])
        backend.listings = [listing(makeTicket(2)), listing(makeTicket(3))]
        gate.release()
        await waitUntil(backend.calls.contains("ignore 1"))
        #expect(backend.calls.filter { $0.hasPrefix("ignore") } == ["ignore 1"])
    }

    @Test func ignoringTwiceIsHarmlessAndUnknownIdsAreIgnored() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1))]
        let gate = SleepGate()
        let controller = makeIgnoreController(backend, gate: gate)
        await controller.reload()
        controller.ignore(1)
        controller.ignore(1)
        controller.ignore(42)
        #expect(controller.pendingIgnores.count == 1)
        controller.undoIgnore()
        controller.undoIgnore()  // 더 되돌릴 게 없다
        #expect(controller.pendingIgnores.isEmpty)
        gate.release()
    }

    @Test func flushCommitsEveryPendingIgnoreWithoutWaiting() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1)), listing(makeTicket(2))]
        let gate = SleepGate()  // 끝내 풀리지 않는다
        let controller = makeIgnoreController(backend, gate: gate)
        await controller.reload()
        controller.ignore(1)
        controller.ignore(2)
        backend.listings = []
        await controller.flushPendingIgnores()
        #expect(backend.calls.filter { $0.hasPrefix("ignore") } == ["ignore 1", "ignore 2"])
        #expect(controller.pendingIgnores.isEmpty)
        gate.release()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(backend.calls.filter { $0.hasPrefix("ignore") }.count == 2)  // 타이머가 다시 확정하지 않는다
    }

    @Test func aFailedIgnoreBringsTheRowBackWithAnError() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1))]
        backend.writeError = Boom()
        let gate = SleepGate()
        let controller = makeIgnoreController(backend, gate: gate)
        await controller.reload()
        controller.ignore(1)
        gate.release()
        await waitUntil(controller.feedback != nil)
        #expect(controller.sections.flatMap(\.rows).map(\.id) == [1])
        #expect(controller.feedback?.isError == true && controller.feedback?.message.contains("boom") == true)
    }

    @Test func ignoringATicketAlreadyGoneIsNotAnError() async {
        struct Gone: MenuBackend {
            func load(now: Date) async throws -> [TicketListing] { [listing(makeTicket(1))] }
            func setStatus(id: Int64, _ status: TicketStatus) async throws {}
            func setNextAction(id: Int64, _ text: String?) async throws {}
            func setTitle(id: Int64, _ title: String) async throws {}
            func go(id: Int64) async -> GoOutcome { GoOutcome(ok: true, message: "") }
            func ignore(id: Int64) async throws { throw StoreError.ticketNotFound(id) }
        }
        let gate = SleepGate()
        let controller = MenuController(backend: Gone(), clock: { epoch }, sleep: { try await gate.sleep($0) })
        await controller.reload()
        controller.ignore(1)
        gate.release()
        await waitUntil(controller.pendingIgnores.isEmpty)
        #expect(controller.feedback == nil)
    }

    @Test func theIgnoredRowCannotBeSelectedOrEditedWhilePending() async {
        let backend = FakeBackend()
        backend.listings = [listing(makeTicket(1)), listing(makeTicket(2))]
        let gate = SleepGate()
        let controller = makeIgnoreController(backend, gate: gate)
        await controller.reload()
        controller.beginEdit(.nextAction, id: 1)
        controller.ignore(1)
        #expect(controller.editing == nil)
        controller.select(1)
        #expect(controller.state.selectedId == 2)
        gate.release()
    }

    // MARK: 보관함

    @Test func archivedRowsGoToTheCollapsedArchiveSectionAndStayOutOfTheBadge() async {
        let backend = FakeBackend()
        backend.listings = [
            listing(makeTicket(1, status: .waiting)),
            listing(makeTicket(2, status: .waiting, archivedAt: epoch)),
            listing(makeTicket(3, status: .active, archivedAt: epoch)),
        ]
        let controller = makeController(backend)
        await controller.reload()
        #expect(controller.badgeCount == 1)
        #expect(controller.sections.map(\.section) == [.waiting, .archive])
        let archive = controller.sections[1]
        #expect(archive.collapsed && archive.rows.map(\.id) == [3, 2] && archive.visibleRows.isEmpty)
        #expect(controller.state.archivedCount == 2)
        controller.toggle(.archive)
        #expect(controller.sections[1].visibleRows.map(\.id) == [3, 2])
        #expect(controller.state.selectableIds(now: controller.now) == [1, 3, 2])
    }

    @Test func openingThePopoverNeverTouchesTheArchiveButTheTimerLoopArchives() async {
        let backend = FakeBackend()
        backend.archivedCount = 1
        let controller = makeController(backend)
        await controller.archiveStale()
        #expect(backend.calls == ["archive", "load"])  // 보관한 게 있으면 목록을 다시 읽는다
        backend.archivedCount = 0
        await controller.archiveStale()
        #expect(backend.calls == ["archive", "load", "archive"])
    }

    @Test func startingTheControllerArchivesOnceUpFront() async throws {
        let backend = FakeBackend()
        let controller = makeController(backend)
        try await withTempDB { path in
            controller.start(databasePath: path, syncInterval: 3_600)
            for _ in 0..<200 where !backend.calls.contains("archive") { try await Task.sleep(for: .milliseconds(5)) }
            controller.stop()
        }
        #expect(backend.calls.first == "archive")
    }

    @Test func theLegendToggleClosesWithThePopover() async {
        let controller = makeController(FakeBackend())
        controller.popoverOpened()
        controller.toggleLegend()
        #expect(controller.showLegend)
        controller.popoverClosed()
        #expect(!controller.showLegend)
    }
}

/// 손으로 돌리는 단조 시계(`uptime`): 리플로 방어(300ms)를 실제로 기다리지 않고 검증한다.
private final class Uptime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

@MainActor
private func makeGuardedController(
    _ backend: FakeBackend, gate: SleepGate, uptime: Uptime, confirmExpires: Bool = false
) -> MenuController {
    MenuController(
        backend: backend, clock: { epoch.addingTimeInterval(60) },
        sleep: { duration in
            // 확인 시간(4초)은 바로 끝나게 하고, 되돌리기 시간(5초)은 게이트로 붙잡는다.
            if confirmExpires && duration == .seconds(4) { return }
            try await gate.sleep(duration)
        },
        uptime: { uptime.now })
}

@MainActor @Suite struct IgnoreConfirmationTests {
    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func controller(
        _ tickets: [Ticket], expires: Bool = false
    ) async -> (MenuController, FakeBackend, SleepGate, Uptime) {
        let backend = FakeBackend()
        backend.listings = tickets.map { listing($0) }
        let gate = SleepGate(), uptime = Uptime()
        let controller = makeGuardedController(backend, gate: gate, uptime: uptime, confirmExpires: expires)
        await controller.reload()
        return (controller, backend, gate, uptime)
    }

    @Test func anUntouchedAutoTicketIsIgnoredWithOneClick() async {
        let (controller, _, gate, _) = await controller([makeTicket(1, "auto"), makeTicket(2)])
        controller.requestIgnore(1)
        #expect(controller.confirmIgnoreId == nil && controller.pendingIgnores.map(\.ticketId) == [1])
        gate.release()
    }

    @Test func aKeptOrEditedTicketNeedsASecondClick() async {
        var withNote = makeTicket(3, "noted")
        withNote.note = "remember"
        let tickets = [makeTicket(1, "kept", kept: true), makeTicket(2, "next", next: "do it"), withNote]
        for ticket in tickets {
            let (controller, backend, gate, _) = await controller(tickets)
            controller.requestIgnore(ticket.id)
            // 첫 클릭: 확인만 묻는다(숨기지도, 5초 타이머도, DB 호출도 없다).
            #expect(controller.confirmIgnoreId == ticket.id && controller.pendingIgnores.isEmpty, "\(ticket.title)")
            #expect(controller.state.selectableIds(now: controller.now).contains(ticket.id))
            #expect(!backend.calls.contains { $0.hasPrefix("ignore") })
            // 같은 티켓을 한 번 더 누르면 무시한다(5초 되돌리기는 그대로).
            controller.requestIgnore(ticket.id)
            #expect(controller.confirmIgnoreId == nil && controller.pendingIgnores.map(\.ticketId) == [ticket.id])
            #expect(controller.pendingIgnores.first?.wasProtected == true)
            controller.undoIgnore()
            #expect(controller.pendingIgnores.isEmpty)
            gate.release()
        }
    }

    @Test func theConfirmationIsDroppedWhenSomethingElseHappens() async {
        let tickets = [makeTicket(1, kept: true), makeTicket(2, kept: true)]
        // 다른 행 선택
        do {
            let (controller, _, gate, _) = await controller(tickets)
            controller.requestIgnore(1)
            controller.select(2)
            #expect(controller.confirmIgnoreId == nil)
            gate.release()
        }
        // 다른 티켓의 🗑: 확인은 그쪽으로 옮겨 간다(둘이 동시에 묻지 않는다).
        do {
            let (controller, _, gate, _) = await controller(tickets)
            controller.requestIgnore(1)
            controller.requestIgnore(2)
            #expect(controller.confirmIgnoreId == 2 && controller.pendingIgnores.isEmpty)
            gate.release()
        }
        // 검색, 팝오버 닫기, 명시적 취소(Esc)
        do {
            let (controller, _, gate, _) = await controller(tickets)
            controller.popoverOpened()
            controller.requestIgnore(1)
            controller.setQuery("x")
            #expect(controller.confirmIgnoreId == nil)
            controller.setQuery("")
            controller.requestIgnore(1)
            controller.cancelIgnoreConfirmation()
            #expect(controller.confirmIgnoreId == nil)
            controller.requestIgnore(1)
            controller.popoverClosed()
            #expect(controller.confirmIgnoreId == nil)
            gate.release()
        }
    }

    @Test func theConfirmationExpiresByItself() async {
        let (controller, _, gate, _) = await controller([makeTicket(1, kept: true)], expires: true)
        controller.requestIgnore(1)
        await waitUntil(controller.confirmIgnoreId == nil)
        #expect(controller.confirmIgnoreId == nil && controller.pendingIgnores.isEmpty)
        gate.release()
    }

    /// 누를 때는 손대지 않은 티켓이었는데 5초 안에 다른 곳에서 ⭐/next_action이 생기면 지우지 않고 되살린다.
    @Test func aTicketKeptDuringTheUndoWindowIsNotDeleted() async {
        let (controller, backend, gate, _) = await controller([makeTicket(1, "auto"), makeTicket(2)])
        controller.requestIgnore(1)
        #expect(controller.pendingIgnores.first?.wasProtected == false)
        backend.listings = [listing(makeTicket(1, "auto", kept: true)), listing(makeTicket(2))]
        await controller.reload()
        gate.release()
        await waitUntil(controller.pendingIgnores.isEmpty)
        #expect(!backend.calls.contains("ignore 1"))
        #expect(controller.state.selectableIds(now: controller.now).contains(1))
        #expect(controller.feedback?.ticketId == 1 && controller.feedback?.isError == false)
    }

    // MARK: S4 reflow guard

    @Test func aDestructiveClickRightAfterARowCollapsedIsDropped() async {
        let (controller, backend, gate, uptime) = await controller([makeTicket(1, "a"), makeTicket(2, "b"), makeTicket(3, "c")])
        await controller.perform(.ignore, on: 1, pressedAt: uptime.now)
        #expect(controller.pendingIgnores.map(\.ticketId) == [1])
        // 더블클릭의 두 번째 클릭: 같은 좌표에 올라온 다음 행(2)의 🗑에 떨어진다 → 버린다.
        uptime.advance(0.1)
        await controller.perform(.ignore, on: 2, pressedAt: uptime.now)
        await controller.perform(.done, on: 2, pressedAt: uptime.now)
        #expect(controller.pendingIgnores.map(\.ticketId) == [1] && !backend.calls.contains("status 2 done"))
        // 가드가 끝난 뒤(≥300ms)의 의도한 클릭은 먹는다.
        uptime.advance(MenuController.reflowGuard + 0.05)
        await controller.perform(.ignore, on: 2, pressedAt: uptime.now)
        #expect(controller.pendingIgnores.map(\.ticketId) == [1, 2])
        gate.release()
    }

    @Test func theGuardMeasuresTheMouseDownTimeNotTheActionTime() async {
        let (controller, _, gate, uptime) = await controller([makeTicket(1), makeTicket(2)])
        await controller.perform(.ignore, on: 1, pressedAt: uptime.now)
        let pressedDuringTheGuard = uptime.now + 0.05
        uptime.advance(1)  // 손을 떼는 것(액션)은 한참 뒤여도, 누른 시각이 가드 안이면 버린다
        await controller.perform(.ignore, on: 2, pressedAt: pressedDuringTheGuard)
        #expect(controller.pendingIgnores.map(\.ticketId) == [1])
        gate.release()
    }

    @Test func theActionIsBoundToTheTicketCapturedAtMouseDown() async {
        let (controller, backend, gate, uptime) = await controller([makeTicket(1), makeTicket(2), makeTicket(3)])
        controller.select(1)  // 선택은 다른 행이어도
        await controller.perform(.done, on: 3, pressedAt: uptime.now)
        #expect(backend.calls.contains("status 3 done") && !backend.calls.contains("status 1 done"))
        gate.release()
    }

    @Test func keepAndEditAreNotGuardedBecauseTheyDoNotMoveRows() async {
        let (controller, backend, gate, uptime) = await controller([makeTicket(1), makeTicket(2)])
        await controller.perform(.ignore, on: 1, pressedAt: uptime.now)
        await controller.perform(.keep, on: 2, pressedAt: uptime.now)
        controller.editing = nil
        await controller.perform(.editNextAction, on: 2, pressedAt: uptime.now)
        #expect(backend.calls.contains("kept 2 true") && controller.editing?.ticketId == 2)
        gate.release()
    }

    @Test func hidingTheSelectedRowMovesTheSelectionToTheNeighbourNotToTheTop() async {
        let (controller, _, gate, uptime) = await controller([makeTicket(1), makeTicket(2), makeTicket(3)])
        controller.select(2)
        await controller.perform(.ignore, on: 2, pressedAt: uptime.now)
        // 화면 순서는 활동 시각 → id 역순(3, 2, 1): 2를 숨기면 그 자리의 다음 행(1)이 선택된다. 맨 위(3)로 튀지 않는다.
        #expect(controller.state.selectedId == 1)
        controller.select(1)
        await controller.perform(.ignore, on: 1, pressedAt: uptime.now + MenuController.reflowGuard + 0.05)
        #expect(controller.state.selectedId == 3)  // 마지막 행을 숨기면 이전 행으로
        gate.release()
    }

    // MARK: S6 keyboard

    @Test func keyboardShortcutsActOnTheSelectedRow() async {
        let (controller, backend, gate, uptime) = await controller([
            makeTicket(1, "kept", kept: true), makeTicket(2, "archived", archivedAt: epoch), makeTicket(3, "plain")])
        controller.select(3)
        await controller.toggleKeepSelected()
        #expect(backend.calls.contains("kept 3 true"))
        controller.toggle(.archive)
        controller.select(2)
        await controller.restoreSelected()
        #expect(backend.calls.contains("restore 2"))
        // 보관함이 아닌 행에는 되살리기가 없다.
        controller.select(3)
        await controller.restoreSelected()
        #expect(backend.calls.filter { $0 == "restore 3" }.isEmpty)
        // ⌘⌫: 유지한 행은 두 번 눌러야 하고, 손대지 않은 행은 한 번이다.
        controller.select(1)
        controller.ignoreSelected()
        #expect(controller.confirmIgnoreId == 1 && controller.pendingIgnores.isEmpty)
        controller.ignoreSelected()
        #expect(controller.pendingIgnores.map(\.ticketId) == [1])
        _ = uptime
        gate.release()
    }
}
