import Foundation

public struct SyncSummary: Equatable, Sendable, Encodable {
    public var created = 0
    public var updated = 0
    public var stale = 0
    public var gone = 0
    /// 다시 보이게 되어 `gone_at`을 지운 위치 수.
    public var revived = 0
    /// 터미널을 찾지 못해(handle 없음) 티켓을 만들지 않은 에이전트 수.
    public var skipped = 0
    /// 오케스트레이션 워커라서 티켓을 만들지 않았거나 지운 탭 수.
    public var workersIgnored = 0
    /// 사용자가 무시한 티켓의 탭이라서 티켓을 다시 만들지 않은 에이전트 수.
    public var ignoredTabs = 0
    /// 탭이 사라져 자동으로 done이 된 티켓 수(유지가 아닌 것만).
    public var autoDone = 0
    /// 일시적 누락으로 자동 완료됐다가 탭이 에이전트와 함께 돌아와 다시 연 티켓 수.
    public var reopened = 0
    /// 24시간 활동이 없어 보관함으로 보낸 티켓 수(유지가 아닌 것만).
    public var archived = 0
    /// 이번 sync에서 워커 handle을 조회했으면 그 결과(조회하지 않았으면 nil). 조회 실패는 여기에 남고 sync를 실패시키지 않는다.
    public var workerRefresh: WorkerRefreshReport?
    public var truncated = false
    public var createdTicketIds: [Int64] = []
    public var staleTicketIds: [Int64] = []
    public var autoDoneTicketIds: [Int64] = []
    public var reopenedTicketIds: [Int64] = []

    public init() {}
}

/// Orca 폴러(`docs/01-product/auto-capture.md`): 스냅샷을 티켓/위치에 병합한다. 프로세스를 띄우지 않는다.
/// 훅이 상태의 1차 소스이고, 폴러는 누락 보정(티켓 생성, handle/제목/프로젝트)과 멈춤 감지, 사라진 탭 표시만 한다.
/// 티켓 상태를 Orca `state`로 덮어쓰지 않는다. 한 번의 sync는 한 트랜잭션이다.
public struct OrcaSync {
    /// `working`인데 이 시간 넘게 `updatedAt`이 멈춰 있으면 `waiting(stale)`.
    public static let staleAfter: TimeInterval = 10 * 60
    /// 탭이 이만큼 연속으로 스냅샷에서 빠져야 `gone_at`을 찍는다(한 번의 빈 응답이나 일시적 누락으로 표시하지 않는다).
    public static let missesBeforeGone = 2
    private static let titleLimit = 60
    /// 무시 표시(`ignored-tab:`)가 이 시간 넘게 남아 있으면 만료시킨다(탭이 열려 있는 채 훅 없는 에이전트를 새로 띄워도 영원히 안 잡히지 않게).
    public static let ignoredTabExpiry: TimeInterval = 14 * 24 * 3_600

    private let store: Store

    public init(store: Store) { self.store = store }

    /// 실제로 쓴다. `workers`는 이번에 조회한 워커 handle이다(5분 제한에 걸려 조회하지 않았으면 nil). 같은 트랜잭션에서 저장한다.
    @discardableResult
    public func apply(_ snapshot: OrcaSnapshot, workers: WorkerFetch? = nil, now: Date) throws -> SyncSummary {
        try store.transaction { try merge(snapshot, workers: workers, now: now) }
    }

    /// 쓰지 않고 `apply`가 했을 일의 요약만 얻는다(같은 로직을 실행한 뒤 롤백).
    @discardableResult
    public func preview(_ snapshot: OrcaSnapshot, workers: WorkerFetch? = nil, now: Date) throws -> SyncSummary {
        try store.rollbackTransaction { try merge(snapshot, workers: workers, now: now) }
    }

    // MARK: Merge

    private func merge(_ snapshot: OrcaSnapshot, workers: WorkerFetch?, now: Date) throws -> SyncSummary {
        var summary = SyncSummary()
        summary.truncated = snapshot.truncated
        var touched = Set<Int64>()  // 이번 sync에서 값이 바뀐 기존 티켓
        var removed = Set<Int64>()  // 워커라서 지운 티켓

        if let workers { summary.workerRefresh = try OrcaWorkers.record(workers, in: store, now: now) }
        let workerHandles = try store.orcaWorkerHandles()
        let ignoredTabs = try store.ignoredOrcaTabs()

        // 탭당 에이전트 하나(가장 최근에 움직인 것). 결정적 순서를 위해 tabId로 정렬한다.
        var agentByTab: [String: OrcaSnapshot.Agent] = [:]
        for agent in snapshot.agents {
            if let known = agentByTab[agent.tabId], (known.updatedAt ?? .distantPast) >= (agent.updatedAt ?? .distantPast) { continue }
            agentByTab[agent.tabId] = agent
        }
        let terminalHandles = Set(snapshot.terminals.map(\.handle))
        let liveTabs = Set(snapshot.terminals.filter { !$0.orphaned }.compactMap(\.tabId)).union(agentByTab.keys)

        // 1) 이미 있는 orca-tab 위치: handle/ptyId/worktreeId/제목 갱신, 멈춤 감지, 사라짐 표시.
        let known = try store.locations(externalKeyPrefix: Self.tabKeyPrefix)
        var knownTabs = Set<String>()
        for location in known {
            guard let key = location.externalKey, case .orcaTerminal(let old) = location.locator else { continue }
            let tabId = String(key.dropFirst(Self.tabKeyPrefix.count))
            knownTabs.insert(tabId)
            if removed.contains(location.ticketId) { continue }
            // 워커 터미널의 티켓은 손대지 않았으면 지우고 그 세션은 이후 수집하지 않는다. 손댄 티켓은 평소처럼 병합한다.
            if workerHandles.contains(old.terminalHandle),
               try OrcaWorker.removeIfUntouched(ticketId: location.ticketId, store: store, reason: OrcaWorker.handleReason) != nil {
                removed.insert(location.ticketId)
                summary.workersIgnored += 1
                continue
            }
            let agent = agentByTab[tabId]
            // handle이 1순위다: 훅이 기록한 정확한 터미널이다. 같은 탭에 터미널이 여럿(분할 pane)이어도 다른 pane의 handle로 덮어쓰지 않는다.
            // 떨어진(orphaned) 터미널도 handle로 맞춘다. handle이 목록에 없을 때만 tabId/leafId로 찾는다.
            let terminal = terminalByHandle(old.terminalHandle, in: snapshot)
                ?? agent.flatMap { matchTerminal(for: $0, in: snapshot) } ?? matchTerminal(tabId: tabId, in: snapshot)
            let present = liveTabs.contains(tabId) || terminalHandles.contains(old.terminalHandle)

            guard present else {
                // 잘렸거나 비었거나 일부를 못 읽은 스냅샷에는 없는 게 정상일 수 있어서 판단하지 않는다(누락 횟수도 그대로).
                // 믿을 수 있는 스냅샷에서 연속으로 빠졌을 때만, 처음 사라진 시각을 남긴다.
                if snapshot.canDetectGone {
                    var justMarked = false
                    if location.goneAt == nil {
                        let misses = try store.recordLocationMiss(id: location.id)
                        if misses >= Self.missesBeforeGone {
                            try store.setLocationGone(id: location.id, at: now)
                            summary.gone += 1
                            justMarked = true
                        }
                    }
                    // 사라진 탭이 티켓의 마지막 살아 있는 탭이고 유지(⭐)가 아니면 자동 완료. 이미 사라져 있던 탭(이 기능 이전)도
                    // 같은 규칙으로 정리하되, 그때는 활동 시간을 올리지 않아 "최근 완료"가 한꺼번에 차지 않게 한다.
                    if location.goneAt != nil || justMarked,
                       try autoDoneIfLastLiveTab(of: location, bumpsActivity: justMarked, now: now, summary: &summary) {
                        touched.insert(location.ticketId)
                    }
                }
                continue
            }
            if location.goneAt != nil {
                summary.revived += 1
                // 일시적 누락으로 자동 완료된 티켓이 에이전트가 다시 일하는 채로 돌아왔다: 다시 연다.
                if try reopenAutoDone(ticketId: location.ticketId, agent: agent, summary: &summary) {
                    touched.insert(location.ticketId)
                }
            }

            let liveTitle = terminal.flatMap { $0.orphaned ? nil : Self.cleanTitle($0.title) }
            var refreshed = old
            if let terminal {
                refreshed.terminalHandle = terminal.handle
                refreshed.ptyId = terminal.ptyId ?? refreshed.ptyId
                refreshed.worktreeId = terminal.worktreeId ?? agent?.worktreeId ?? refreshed.worktreeId
                if let liveTitle { refreshed.titleHint = liveTitle }
            } else if refreshed.worktreeId == nil {
                refreshed.worktreeId = agent?.worktreeId
            }
            // upsert가 lastSeenAt을 갱신하고 gone_at을 지운다(티켓 소속과 최초 source는 유지).
            try store.upsertLocation(
                byExternalKey: key, ticketId: location.ticketId, locator: .orcaTerminal(refreshed), source: .orcaSync)
            if refreshed != old { touched.insert(location.ticketId) }

            guard let agent else { continue }
            var ticket = try store.getTicket(id: location.ticketId)
            if let liveTitle, liveTitle != ticket.title, try store.autoUpdateTitle(id: ticket.id, title: liveTitle) {
                touched.insert(ticket.id)
            }
            if ticket.project == nil, let project = Self.baseName(agent.worktreePath ?? terminal?.worktreePath) {
                try store.patchTicket(id: ticket.id, TicketPatch(project: .some(project)))
                touched.insert(ticket.id)
            }
            ticket = try store.getTicket(id: ticket.id)
            // 훅의 최근 활동도 살아 있다는 증거다: Orca 상태(updatedAt)와 티켓의 마지막 활동 중 더 최근 것을 기준으로 한다.
            if ticket.status == .active, agent.state == "working", let updated = agent.updatedAt,
               now.timeIntervalSince(max(updated, ticket.lastActivityAt)) > Self.staleAfter {
                try store.patchTicket(
                    id: ticket.id, TicketPatch(status: .waiting, waitingReason: .some(.stale), bumpsActivity: false))
                summary.stale += 1
                summary.staleTicketIds.append(ticket.id)
            }
        }

        // 2) 위치가 없는 에이전트: inbox 티켓을 만든다. 터미널(handle)을 못 찾으면 만들지 않는다.
        for tabId in agentByTab.keys.sorted() where !knownTabs.contains(tabId) {
            let agent = agentByTab[tabId]!
            // 사용자가 무시한 티켓의 탭: 에이전트가 목록에 남아 있는 동안 같은 탭으로 티켓을 다시 만들지 않는다.
            if ignoredTabs[tabId] != nil {
                summary.ignoredTabs += 1
                continue
            }
            guard let terminal = matchTerminal(for: agent, in: snapshot) else {
                summary.skipped += 1
                continue
            }
            if workerHandles.contains(terminal.handle) {
                summary.workersIgnored += 1
                continue
            }
            let locator = Locator.orcaTerminal(.init(
                terminalHandle: terminal.handle, worktreeId: terminal.worktreeId ?? agent.worktreeId, tabId: tabId,
                ptyId: terminal.ptyId, titleHint: terminal.orphaned ? nil : Self.cleanTitle(terminal.title)))
            let title = (terminal.orphaned ? nil : Self.cleanTitle(terminal.title))
                ?? agent.prompt.flatMap(Reconciler.title(fromPrompt:))
                ?? "\(agent.agentType ?? "agent") session"
            let result = try store.upsertTicketAndLocation(
                externalKey: Self.tabKeyPrefix + tabId, locator: locator, source: .orcaSync,
                newTicket: NewTicket(
                    title: title, status: .inbox, project: Self.baseName(agent.worktreePath ?? terminal.worktreePath),
                    lastActivityAt: agent.updatedAt))
            if result.created {
                summary.created += 1
                summary.createdTicketIds.append(result.ticket.id)
            }
        }

        // 무시 표시한 탭이 믿을 수 있는 스냅샷에서 연속으로 사라졌으면 표시를 푼다(탭이 닫혔다: 같은 탭 ID는 다시 쓰이지 않는다).
        // 다시 보이면 횟수를 0으로 되돌린다.
        let seenTabs = liveTabs.union(snapshot.terminals.compactMap(\.tabId))
        for (tabId, misses) in ignoredTabs {
            if seenTabs.contains(tabId) {
                if misses != 0 { try store.setIgnoredOrcaTabMisses(tabId, misses: 0) }
            } else if snapshot.canDetectGone {
                try store.setIgnoredOrcaTabMisses(tabId, misses: misses + 1 >= Self.missesBeforeGone ? nil : misses + 1)
            }
        }

        try store.expireIgnoredOrcaTabs(olderThan: Self.ignoredTabExpiry, now: now)
        // 자동 보관: 유지가 아닌 티켓이 24시간 활동이 없으면 보관함으로(상태는 그대로).
        summary.archived = try store.archiveStale(now: now)
        summary.updated = touched.subtracting(removed).count
        return summary
    }

    /// 사라진 탭(`location`)이 이 티켓의 마지막 살아 있는 탭이면(다른 `orca_terminal` 위치 중 사라지지 않은 것이 없다) done으로 바꾼다.
    /// 세션 위치(`claude_code`, `codex_thread`)와 웹 위치는 "살아 있는지"를 알 수 없고 Codex에는 `SessionEnd`가 없어서
    /// 터미널만 센다. 유지(⭐)이거나 이미 done이거나 blocked(사용자만 정하는 상태)면 아무것도 하지 않는다.
    /// done으로 바꿀 때 자동 완료 표지(`autoDoneAt`)를 남긴다: 나중에 같은 세션이 움직이면 다시 열 수 있다. 바꿨으면 true.
    private func autoDoneIfLastLiveTab(
        of location: Location, bumpsActivity: Bool, now: Date, summary: inout SyncSummary
    ) throws -> Bool {
        let ticket = try store.getTicket(id: location.ticketId)
        guard !ticket.kept, ticket.status != .done, ticket.status != .blocked else { return false }
        let otherLiveTab = try store.locations(ticketId: ticket.id).contains {
            $0.id != location.id && $0.kind == .orcaTerminal && $0.goneAt == nil
        }
        guard !otherLiveTab else { return false }
        try store.patchTicket(id: ticket.id, TicketPatch(status: .done, autoDoneAt: .some(now), bumpsActivity: bumpsActivity))
        summary.autoDone += 1
        summary.autoDoneTicketIds.append(ticket.id)
        return true
    }

    /// 사라졌다 돌아온 탭의 티켓이 자동 완료 표지가 있는 done이고, 에이전트가 그 뒤로 다시 `working`이면 진행 중으로 연다.
    /// 에이전트가 일하지 않거나(Orca 재시작 뒤 떨어진 옛 탭이 `done` 상태로 남아 보이는 경우 포함) 자동 완료보다 오래된 상태면
    /// 열지 않는다: 끝난 티켓이 소음으로 되살아나지 않게, "다시 움직였다"는 증거가 있을 때만 연다. 사용자가 닫은 티켓은 표지가 없어 열지 않는다.
    private func reopenAutoDone(ticketId: Int64, agent: OrcaSnapshot.Agent?, summary: inout SyncSummary) throws -> Bool {
        guard let agent, agent.state == "working", let updated = agent.updatedAt else { return false }
        let ticket = try store.getTicket(id: ticketId)
        guard ticket.status == .done, let autoDoneAt = ticket.autoDoneAt, updated > autoDoneAt else { return false }
        try store.patchTicket(id: ticketId, Reconciler.reopenPatch)
        summary.reopened += 1
        summary.reopenedTicketIds.append(ticketId)
        return true
    }

    // MARK: Matching

    static let tabKeyPrefix = "orca-tab:"

    /// 에이전트의 터미널: 같은 `tabId`(같은 leaf 우선) → 없으면 `leafId`로 → 없으면 nil.
    private func matchTerminal(for agent: OrcaSnapshot.Agent, in snapshot: OrcaSnapshot) -> OrcaSnapshot.Terminal? {
        let sameTab = snapshot.terminals.filter { $0.tabId == agent.tabId }
        if let leaf = agent.leafId, let exact = sameTab.first(where: { $0.leafId == leaf }) { return exact }
        if let first = sameTab.first(where: { !$0.orphaned }) ?? sameTab.first { return first }
        if let leaf = agent.leafId { return snapshot.terminals.first { $0.leafId == leaf } }
        return nil
    }

    private func matchTerminal(tabId: String, in snapshot: OrcaSnapshot) -> OrcaSnapshot.Terminal? {
        let sameTab = snapshot.terminals.filter { $0.tabId == tabId }
        return sameTab.first(where: { !$0.orphaned }) ?? sameTab.first
    }

    private func terminalByHandle(_ handle: String, in snapshot: OrcaSnapshot) -> OrcaSnapshot.Terminal? {
        snapshot.terminals.first { $0.handle == handle }
    }

    // MARK: Title / project

    /// 터미널 제목에서 앞의 상태 기호(`✳ ◐ ◑`, 점자 스피너 등: 공백과 유니코드 기호 문자)를 뗀다.
    /// `#39`처럼 뜻이 있는 문장부호는 남긴다. 셸 경로처럼 보이는 제목(`~/…`, `/…`, `..…`)이나 빈 제목은 nil.
    static func cleanTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("~") || trimmed.hasPrefix("/") || trimmed.hasPrefix("..") { return nil }
        let symbols: Set<Unicode.GeneralCategory> = [.mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol]
        var scalars = Substring(trimmed).unicodeScalars[...]
        while let first = scalars.first,
              first.properties.isWhitespace || symbols.contains(first.properties.generalCategory) {
            scalars = scalars.dropFirst()
        }
        let title = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func baseName(_ path: String?) -> String? {
        guard let path else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
