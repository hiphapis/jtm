import Foundation
import Observation
import JTMCore

/// 행 아래에 보여줄 한 줄 메시지(이동 실패, 클립보드 복사 안내 등).
public struct Feedback: Equatable, Sendable {
    public var ticketId: Int64
    public var message: String
    public var isError: Bool
}

/// 인라인 편집 중인 필드.
public struct EditSession: Equatable, Sendable {
    public enum Field: Sendable { case nextAction, title }
    public var ticketId: Int64
    public var field: Field
    public var draft: String
}

/// 🗑을 눌러 숨겨 둔 티켓. 되돌리기 시간이 끝나면 실제로 무시(삭제)한다.
public struct PendingIgnore: Equatable, Identifiable, Sendable {
    public var ticketId: Int64
    public var title: String
    /// 누를 때 이미 ⭐/next_action/note가 있던 티켓인가(그때는 확인을 거쳤다). 누를 때는 없었는데 5초 안에 다른 곳(CLI)에서
    /// 생겼다면 확정하지 않고 취소한다.
    public var wasProtected = false
    public var id: Int64 { ticketId }
}

/// 팝오버의 상태와 동작. UI 프레임워크를 모른다: 뷰는 읽고 호출만 하고, 팝오버 닫기는 주입받은 클로저로 부탁한다.
@MainActor @Observable
public final class MenuController {
    public private(set) var state = MenuState()
    public private(set) var syncOutcome: SyncOutcome?
    public private(set) var feedback: Feedback?
    public private(set) var loadError: String?
    public private(set) var isOpen = false
    /// 열릴 때마다 오른다. 오래 걸리는 이동이 끝났을 때 그사이 새로 열린 팝오버를 닫지 않기 위해 쓴다.
    public private(set) var openGeneration = 0
    /// 무시를 눌렀고 되돌리기 시간이 안 끝난 티켓들(오래된 것부터). 푸터가 마지막 것을 "되돌리기"로 보여준다.
    public private(set) var pendingIgnores: [PendingIgnore] = []
    /// 푸터 "?" 버튼이 연 범례를 보이고 있는가.
    public var showLegend = false
    /// 🗑을 한 번 눌러 "정말 지울까요?"를 묻고 있는 티켓(⭐/next_action/note가 있는 티켓만). 한 번 더 누르면 지운다.
    public private(set) var confirmIgnoreId: Int64?
    /// 열릴 때마다 오른다. 뷰가 이 값이 바뀌면 검색창에 포커스를 준다.
    public private(set) var focusToken = 0
    /// "N분 전" 표시의 기준 시각(목록을 읽거나 팝오버를 열 때 갱신).
    public private(set) var now: Date
    public var editing: EditSession?

    /// 이동이 끝나 팝오버를 닫아야 할 때 부른다.
    public var closePopover: @MainActor () -> Void = {}
    /// 팝오버가 닫힌 뒤에 알려야 할 메시지(이동 실패, 클립보드 복사)가 생겼을 때 다시 열어 달라고 부탁한다.
    /// 열기를 시작했으면 true. 실제로 열리면 그때 `popoverOpened()`가 불린다(아이콘이 숨겨졌으면 앵커 없는 패널이 열린다).
    public var presentPopover: @MainActor () -> Bool = { false }

    private let backend: MenuBackend
    private let sync: @Sendable (SyncTrigger) async -> SyncOutcome?
    private let clock: @Sendable () -> Date
    private let ignoreUndoDelay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let uptime: @Sendable () -> TimeInterval
    private let confirmTimeout: Duration
    private var ignoreTimers: [Int64: Task<Void, Never>] = [:]
    private var confirmTimer: Task<Void, Never>?
    /// 행이 접히거나 옮겨 간(지우기·완료·되살리기) 마지막 시각(`uptime`). 그 직후의 클릭은 리플로로 다음 행에 떨어진 것이다.
    private var lastReflowAt: TimeInterval = -.infinity
    private var watcher: DatabaseWatcher?
    private var syncLoop: Task<Void, Never>?
    private var isReloading = false
    private var reloadQueued = false
    private var isGoing = false
    /// 다시 열어서 보여 줄 메시지가 있으면 다음 `popoverOpened()`가 지우지 않는다.
    private var keepFeedbackOnNextOpen = false

    public init(
        backend: MenuBackend,
        sync: @escaping @Sendable (SyncTrigger) async -> SyncOutcome? = { _ in nil },
        clock: @escaping @Sendable () -> Date = { Date() },
        ignoreUndoDelay: Duration = .seconds(5),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        confirmTimeout: Duration = .seconds(4)
    ) {
        self.backend = backend
        self.sync = sync
        self.clock = clock
        self.ignoreUndoDelay = ignoreUndoDelay
        self.sleep = sleep
        self.uptime = uptime
        self.confirmTimeout = confirmTimeout
        self.now = clock()
    }

    public var badgeCount: Int { state.badgeCount }
    public var sections: [MenuSectionModel] { state.sections(now: now) }
    public var footerNotice: String? { syncOutcome?.footerNotice }
    /// 푸터에 "되돌리기"와 함께 보일 가장 최근의 무시.
    public var undoNotice: PendingIgnore? { pendingIgnores.last }

    // MARK: Background work

    /// DB 감시와 30초 동기화를 시작한다. 팝오버가 닫혀 있으면(배지만 필요하다) 감시가 더 느슨한 디바운스를 쓴다.
    public func start(databasePath: String, syncInterval: TimeInterval = 30, watch: DatabaseWatcher.Options = .init()) {
        stop()
        let watcher = DatabaseWatcher(path: databasePath, options: watch) { [weak self] in
            Task { @MainActor in await self?.reload() }
        }
        watcher.setActive(isOpen)
        watcher.start()
        self.watcher = watcher
        syncLoop = Task { [weak self] in
            // 앱이 뜰 때 한 번 자동 보관을 돌린다(싼 UPDATE 한 문장). Orca가 꺼져 있으면 폴러가 안 돌아서 타이머마다 한 번 더 돈다.
            await self?.archiveStale()
            await self?.reload()
            await self?.runSync(.timer)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(syncInterval))
                guard !Task.isCancelled else { return }
                self?.refreshNow()
                await self?.archiveStale()
                await self?.runSync(.timer)
            }
        }
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        syncLoop?.cancel()
        syncLoop = nil
    }

    /// 24시간 활동이 없는 유지 안 한 티켓을 보관함으로 보낸다. 실패는 조용히 넘긴다(다음에 다시 시도한다).
    /// 바뀐 게 있으면 목록을 다시 읽는다.
    public func archiveStale() async {
        guard let count = try? await backend.archiveStale(now: clock()), count > 0 else { return }
        await reload()
    }

    /// 팝오버가 열려 있는 동안 "N분 전" 표시가 낡지 않게 기준 시각을 옮긴다.
    private func refreshNow() {
        if isOpen { now = clock() }
    }

    public func runSync(_ trigger: SyncTrigger) async {
        guard let outcome = await sync(trigger) else { return }
        if outcome == .busy {  // 도는 동기화가 끝나면 그 결과가 이 문구를 대신한다
            syncOutcome = .busy
            return
        }
        syncOutcome = outcome
        if case .synced = outcome { await reload() }
    }

    /// 동시에 여러 번 불려도 읽기는 하나씩만 하고, 겹친 요청은 한 번 더 읽는 것으로 합친다.
    public func reload() async {
        if isReloading { reloadQueued = true; return }
        isReloading = true
        defer { isReloading = false }
        repeat {
            reloadQueued = false
            do {
                let listings = try await backend.load(now: clock())
                // 같은 목록이면 아무것도 대입하지 않는다: `@Observable`은 같은 값을 다시 넣어도 화면을 무효화한다.
                // 시각(`now`)은 목록이 바뀌었거나 팝오버가 열려 있을 때만 갱신한다("N분 전" 표시용).
                if listings != state.listings {
                    now = clock()
                    state.apply(listings, now: now)
                } else if isOpen {
                    now = clock()
                }
                if loadError != nil { loadError = nil }
            } catch {
                let message = "\(error)"
                if loadError != message { loadError = message }
            }
        } while reloadQueued
    }

    // MARK: Popover lifecycle

    public func popoverOpened() {
        isOpen = true
        openGeneration += 1
        watcher?.setActive(true)
        // 열 때 남아 있는 메시지는 지난번 것이다. 방금 그 메시지를 보이려고 다시 연 경우만 남긴다.
        if keepFeedbackOnNextOpen { keepFeedbackOnNextOpen = false } else { feedback = nil }
        focusToken += 1
        now = clock()
        Task { await reload() }
        Task { await runSync(.open) }
    }

    public func popoverClosed() {
        cancelIgnoreConfirmation()
        isOpen = false
        watcher?.setActive(false)
        keepFeedbackOnNextOpen = false
        editing = nil
        feedback = nil
        showLegend = false
        state.setQuery("", now: clock())
    }

    // MARK: Search / selection

    public func setQuery(_ text: String) {
        state.setQuery(text, now: now)
        clearTransient()
    }

    public func moveSelection(by delta: Int) {
        state.moveSelection(by: delta, now: now)
        clearTransient()
    }

    public func select(_ id: Int64) {
        state.select(id, now: now)
        if editing?.ticketId != id { editing = nil }
        if confirmIgnoreId != id { cancelIgnoreConfirmation() }
    }

    public func toggleDone() {
        state.toggleDone(now: now)
    }

    /// "최근 완료"와 "보관함"의 접힘을 바꾼다.
    public func toggle(_ section: MenuSection) {
        state.toggle(section, now: now)
    }

    public func toggleLegend() { showLegend.toggle() }

    private func clearTransient() {
        if confirmIgnoreId != state.selectedId { cancelIgnoreConfirmation() }
        if let selected = state.selectedId {
            if editing?.ticketId != selected { editing = nil }
            if feedback?.ticketId != selected { feedback = nil }
        } else {
            editing = nil
            feedback = nil
        }
    }

    // MARK: Go

    public func activateSelected() async {
        guard let id = state.selectedId else { return }
        await activate(id)
    }

    /// 클릭/Enter: 이동한 뒤 팝오버를 닫는다. 실패하거나 클립보드에 복사만 했으면 닫지 않고 행 아래에 메시지를 보여준다.
    /// Orca 이동은 Orca를 앞으로 올리므로 팝오버가 이미 닫혀 있을 수 있다: 그때는 메시지를 보이도록 다시 연다.
    public func activate(_ id: Int64) async {
        guard !isGoing else { return }
        isGoing = true
        defer { isGoing = false }
        let generation = openGeneration
        state.select(id, now: now)
        editing = nil
        feedback = Feedback(ticketId: id, message: L10n.string(.feedbackGoing), isError: false)
        let outcome = await backend.go(id: id)
        if outcome.ok && !outcome.copiedToClipboard {
            feedback = nil
            // 이동하는 동안 사용자가 팝오버를 닫았다 다시 열었으면 새 팝오버는 그대로 둔다.
            if isOpen && generation == openGeneration { closePopover() }
        } else if outcome.copiedToClipboard {
            showFeedback(Feedback(ticketId: id, message: L10n.string(.feedbackCopied), isError: false))
        } else {
            showFeedback(Feedback(ticketId: id, message: L10n.string(.feedbackGoFailed, Self.shorten(outcome.message)), isError: true))
        }
        await reload()
    }

    /// 메시지를 세우고, 팝오버가 닫혀 있으면 그 메시지를 보이도록 다시 연다.
    private func showFeedback(_ message: Feedback) {
        if state.listing(id: message.ticketId)?.ticket.status == .done { state.doneExpanded = true }
        feedback = message
        if !isOpen {
            keepFeedbackOnNextOpen = true
            // 열지 못했다(앵커도 패널도 없음)면 다음 열기에 낡은 메시지를 남기지 않는다.
            if !presentPopover() { keepFeedbackOnNextOpen = false }
        }
    }

    private static func shorten(_ text: String) -> String {
        text.count > 140 ? String(text.prefix(140)) + "…" : text
    }

    // MARK: Actions on a ticket

    public func setStatus(_ id: Int64, _ status: TicketStatus) async {
        await perform(id) { try await self.backend.setStatus(id: id, status) }
    }

    public func markDoneSelected() async {
        guard let id = state.selectedId else { return }
        await setStatus(id, .done)
    }

    // MARK: Row buttons (⭐ ✎ ✓ 🗑 / 되살리기)

    public func markDone(_ id: Int64) async { await setStatus(id, .done) }

    /// ⭐ 토글.
    public func toggleKeep(_ id: Int64) async {
        guard let kept = state.listing(id: id)?.ticket.kept else { return }
        await perform(id) { try await self.backend.setKept(id: id, !kept) }
    }

    /// 보관함에서 되살린다(보관 해제 + 유지).
    public func restore(_ id: Int64) async {
        await perform(id) { try await self.backend.restore(id: id) }
    }

    // MARK: Row button entry point (reflow guard)

    /// 리플로 뒤 이 시간 안의 파괴적 클릭(🗑 ✓ 되살리기)은 버린다. 더블클릭의 두 번째 클릭이 첫 클릭으로 올라온 다음 행에 떨어지는 사고를 막는다.
    public static let reflowGuard: TimeInterval = 0.3

    /// 지금 시각(`uptime`). 뷰가 마우스를 누른 순간을 기록해 `perform(_:on:pressedAt:)`에 넘긴다.
    public func pressTimestamp() -> TimeInterval { uptime() }

    /// 행 버튼의 단 하나의 진입점. `id`는 **마우스를 누른 순간의 행**이고(누른 뒤에 목록이 바뀌어도 다음 행으로 옮겨 가지 않는다),
    /// `pressedAt`은 그때의 `pressTimestamp()`다. 리플로(🗑·✓·되살리기로 행이 접힘) 직후 `reflowGuard` 안에 누른 파괴적 버튼은 무시한다.
    public func perform(_ action: RowAction, on id: Int64, pressedAt: TimeInterval? = nil) async {
        let pressed = pressedAt ?? uptime()
        switch action {
        case .keep: await toggleKeep(id)
        case .editNextAction: beginEdit(.nextAction, id: id)
        case .ignore, .done, .restore:
            guard pressed - lastReflowAt >= Self.reflowGuard else { return }
            switch action {
            case .ignore: requestIgnore(id)
            case .done:
                lastReflowAt = uptime()
                await markDone(id)
            default:
                lastReflowAt = uptime()
                await restore(id)
            }
        }
    }

    // MARK: Keyboard (selected row)

    /// ⌘S: 선택한 행의 ⭐ 토글.
    public func toggleKeepSelected() async {
        guard let id = state.selectedId else { return }
        await perform(.keep, on: id)
    }

    /// ⌘⌫: 선택한 행 무시(⭐/next_action/note가 있으면 한 번 더 눌러 확인).
    public func ignoreSelected() {
        guard let id = state.selectedId else { return }
        requestIgnore(id)
    }

    /// ⌘R: 선택한 행이 보관함에 있으면 되살린다.
    public func restoreSelected() async {
        guard let id = state.selectedId, state.listing(id: id)?.ticket.archivedAt != nil else { return }
        await perform(.restore, on: id)
    }

    // MARK: Ignore confirmation

    /// 🗑을 눌렀다. 손대지 않은 자동 티켓은 곧바로 무시(5초 되돌리기)하고, ⭐/next_action/note가 있는 티켓은
    /// 처음에는 "정말 지울까요?"로 바꾸기만 하고(`confirmIgnoreId`) 같은 티켓을 한 번 더 눌러야 무시한다.
    /// 확인은 `confirmTimeout` 뒤, 다른 행을 고르거나 검색·Esc·팝오버를 닫으면 풀린다.
    public func requestIgnore(_ id: Int64) {
        guard let ticket = state.listing(id: id)?.ticket else { return }
        guard ticket.needsIgnoreConfirmation else {
            ignore(id)
            return
        }
        if confirmIgnoreId == id {
            cancelIgnoreConfirmation()
            ignore(id)
            return
        }
        cancelIgnoreConfirmation()
        confirmIgnoreId = id
        confirmTimer = Task { [weak self, confirmTimeout, sleep] in
            try? await sleep(confirmTimeout)
            guard !Task.isCancelled else { return }
            self?.expireIgnoreConfirmation(id)
        }
    }

    public func cancelIgnoreConfirmation() {
        confirmTimer?.cancel()
        confirmTimer = nil
        confirmIgnoreId = nil
    }

    private func expireIgnoreConfirmation(_ id: Int64) {
        if confirmIgnoreId == id { confirmIgnoreId = nil }
        confirmTimer = nil
    }

    /// 🗑 무시. 확인창 없이 바로 목록에서 숨기고, `ignoreUndoDelay`(5초) 뒤에 실제로 무시한다(티켓 삭제 + 세션 무시 목록).
    /// 그 안에 `undoIgnore()`를 부르면 아무 일도 없었던 것이 된다: DB는 그동안 그대로라서 되돌리기가 "다시 만들기"가 아니다.
    /// 앱을 끝낼 때는 `flushPendingIgnores()`가 남은 것을 바로 확정한다.
    /// 이 메서드 자체는 확인·리플로 방어를 하지 않는다: 행 버튼과 단축키는 `perform`/`requestIgnore`를 거친다.
    public func ignore(_ id: Int64) {
        guard let ticket = state.listing(id: id)?.ticket, !pendingIgnores.contains(where: { $0.ticketId == id }) else { return }
        if editing?.ticketId == id { editing = nil }
        if feedback?.ticketId == id { feedback = nil }
        if confirmIgnoreId == id { cancelIgnoreConfirmation() }
        pendingIgnores.append(PendingIgnore(ticketId: id, title: ticket.title, wasProtected: ticket.needsIgnoreConfirmation))
        lastReflowAt = uptime()
        state.hide(id, now: now)
        ignoreTimers[id] = Task { [weak self, ignoreUndoDelay, sleep] in
            try? await sleep(ignoreUndoDelay)
            guard !Task.isCancelled else { return }
            await self?.commitIgnore(id)
        }
    }

    /// 가장 최근에 무시한 티켓을 되살린다(되돌리기 시간 안에서만 의미가 있다).
    public func undoIgnore() {
        guard let last = pendingIgnores.popLast() else { return }
        ignoreTimers.removeValue(forKey: last.ticketId)?.cancel()
        state.unhide(last.ticketId, now: now)
        state.select(last.ticketId, now: now)
    }

    /// 되돌리기 시간을 기다리지 않고 남은 무시를 모두 확정한다(앱 종료 직전).
    public func flushPendingIgnores() async {
        for pending in pendingIgnores {
            ignoreTimers.removeValue(forKey: pending.ticketId)?.cancel()
            await commitIgnore(pending.ticketId)
        }
    }

    private func commitIgnore(_ id: Int64) async {
        guard let index = pendingIgnores.firstIndex(where: { $0.ticketId == id }) else { return }
        let pending = pendingIgnores.remove(at: index)
        ignoreTimers[id] = nil
        // 누를 때는 손대지 않은 티켓이었는데 그 사이 다른 곳(CLI `jtm keep`/`set --note`)에서 챙겼다: 지우지 않고 되살린다.
        // (`updated_at`은 훅이 계속 바꾸므로 보지 않고, 사용자가 챙긴 표지만 본다.)
        if !pending.wasProtected, state.listing(id: id)?.ticket.needsIgnoreConfirmation == true {
            state.unhide(id, now: now)
            feedback = Feedback(ticketId: id, message: L10n.string(.feedbackNotIgnored), isError: false)
            return
        }
        do {
            try await backend.ignore(id: id)
        } catch StoreError.ticketNotFound {
            // 그 사이 다른 곳(CLI)에서 이미 지웠다: 원하던 결과다.
        } catch {
            state.unhide(id, now: now)
            feedback = Feedback(ticketId: id, message: L10n.string(.feedbackIgnoreFailed, "\(error)"), isError: true)
        }
        await reload()
    }

    private func perform(_ id: Int64, _ work: () async throws -> Void) async {
        do {
            try await work()
            feedback = nil
        } catch {
            feedback = Feedback(ticketId: id, message: L10n.string(.feedbackSaveFailed, "\(error)"), isError: true)
        }
        await reload()
    }

    // MARK: Inline editing

    public func beginEdit(_ field: EditSession.Field, id: Int64? = nil) {
        guard let id = id ?? state.selectedId, let ticket = state.listing(id: id)?.ticket else { return }
        state.select(id, now: now)
        feedback = nil
        editing = EditSession(
            ticketId: id, field: field, draft: field == .nextAction ? (ticket.nextAction ?? "") : ticket.title)
    }

    public func cancelEdit() { editing = nil }

    public func commitEdit() async {
        guard let session = editing else { return }
        editing = nil
        switch session.field {
        case .nextAction:
            await perform(session.ticketId) { try await self.backend.setNextAction(id: session.ticketId, session.draft) }
        case .title:
            // 빈 제목은 저장하지 않는다.
            guard !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await perform(session.ticketId) { try await self.backend.setTitle(id: session.ticketId, session.draft) }
        }
    }
}
