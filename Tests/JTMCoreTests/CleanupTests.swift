import Foundation
import Testing
@testable import JTMCore

// 자동 정리(유지/완료/보관/무시): docs/01-product/menubar-ui.md "자동 정리와 행 버튼".

private struct NoProject: ProjectResolver {
    func gitTopLevel(containing cwd: String) -> String? { nil }
}

private let cwd = "/Users/me/Work/app"
private let wtId = "wt-uuid::/Users/me/Work/app-wt"
private let day: TimeInterval = 24 * 3_600

private func claudeEvent(_ kind: AgentEventKind, session: String = "s1", prompt: String? = nil) -> AgentEvent {
    AgentEvent(agent: .claude, kind: kind, sessionId: session, cwd: cwd, prompt: prompt)
}

private func env(tab: String = "tab-1", handle: String = "term_1") -> OrcaEnv {
    OrcaEnv(terminalHandle: handle, tabId: tab, worktreeId: wtId)
}

private func agent(_ tab: String, updated: Date) -> OrcaSnapshot.Agent {
    .init(paneKey: "\(tab):leaf-1", state: "done", agentType: "claude", prompt: nil, updatedAt: updated,
          worktreeId: wtId, worktreePath: "/Users/me/Work/app-wt")
}

private func terminal(_ tab: String, handle: String = "term_1") -> OrcaSnapshot.Terminal {
    .init(handle: handle, ptyId: "pty-\(tab)", tabId: tab, leafId: "leaf-1", title: "✳ Fix login", orphaned: false,
          worktreeId: wtId, worktreePath: "/Users/me/Work/app-wt")
}

private func snapshot(_ agents: [OrcaSnapshot.Agent] = [], _ terminals: [OrcaSnapshot.Terminal] = []) -> OrcaSnapshot {
    OrcaSnapshot(agents: agents, terminals: terminals, truncated: false, droppedElements: 0)
}

private let otherTab = snapshot([], [terminal("other", handle: "term_other")])

@Suite struct CleanupStoreTests {
    // MARK: kept

    @Test func userEditsKeepATicketButAutomaticPatchesDoNot() throws {
        try withStore { store, _, _ in
            func fresh() throws -> Int64 { try store.createTicket(title: "t", status: .active).id }
            // 자동 수집이 쓰는 patchTicket은 어떤 필드를 바꿔도 kept를 올리지 않는다.
            let auto = try fresh()
            try store.patchTicket(id: auto, TicketPatch(title: "x", status: .waiting, nextAction: .some("n"), note: .some("m")))
            #expect(try store.getTicket(id: auto).kept == false)

            let cases: [(String, TicketPatch, Bool)] = [
                ("title", TicketPatch(title: "new"), true),
                ("next_action", TicketPatch(nextAction: .some("go")), true),
                ("next_action cleared", TicketPatch(nextAction: .some(nil)), true),
                ("note", TicketPatch(note: .some("n")), true),
                ("status active", TicketPatch(status: .active), true),
                ("status blocked", TicketPatch(status: .blocked), true),
                ("status done", TicketPatch(status: .done), false),
                ("project", TicketPatch(project: .some("p")), true),
                ("priority", TicketPatch(priority: .some(2)), true),
                ("priority cleared", TicketPatch(priority: .some(nil)), true),
                ("unpin title", TicketPatch(pinnedTitle: false), false),
            ]
            for (name, patch, expected) in cases {
                let id = try fresh()
                try store.patchTicketAsUser(id: id, patch)
                #expect(try store.getTicket(id: id).kept == expected, "\(name)")
            }
        }
    }

    @Test func setKeptTogglesAndKeepingClearsArchive() throws {
        try withStore { store, clock, _ in
            let id = try store.createTicket(title: "t", status: .active).id
            clock.advance(2 * day)
            #expect(try store.archiveStale() == 1)
            #expect(try store.getTicket(id: id).archivedAt != nil)
            let kept = try store.setKept(id: id, true)
            #expect(kept.kept && kept.archivedAt == nil)
            let unkept = try store.setKept(id: id, false)
            #expect(!unkept.kept && unkept.archivedAt == nil)
        }
    }

    // MARK: archive

    @Test func archiveStaleHidesOnlyOldUnkeptNotDoneTicketsAndKeepsTheirStatus() throws {
        try withStore { store, clock, _ in
            let old = try store.createTicket(title: "old", status: .waiting, nextAction: nil)
            let oldKept = try store.createTicket(title: "kept", status: .active)
            try store.setKept(id: oldKept.id, true)
            let oldDone = try store.createTicket(title: "done", status: .done)
            clock.advance(day + 10)
            let recent = try store.createTicket(title: "recent", status: .active)

            #expect(try store.archiveStale() == 1)
            let archived = try store.getTicket(id: old.id)
            #expect(archived.archivedAt == clock.current && archived.status == .waiting)
            #expect(try store.getTicket(id: oldKept.id).archivedAt == nil)
            #expect(try store.getTicket(id: oldDone.id).archivedAt == nil)
            #expect(try store.getTicket(id: recent.id).archivedAt == nil)
            #expect(try store.archiveStale() == 0)  // 두 번째는 할 일이 없다
        }
    }

    @Test func archiveBoundaryIsExactlyTwentyFourHours() throws {
        try withStore { store, clock, _ in
            let id = try store.createTicket(title: "t", status: .active).id
            clock.advance(day)  // 정확히 24시간: 아직 아니다
            #expect(try store.archiveStale() == 0)
            clock.advance(1)
            #expect(try store.archiveStale() == 1 && store.getTicket(id: id).archivedAt != nil)
        }
    }

    @Test func listFiltersByArchiveScope() throws {
        try withStore { store, clock, _ in
            let old = try store.createTicket(title: "old", status: .active).id
            clock.advance(2 * day)
            let fresh = try store.createTicket(title: "fresh", status: .active).id
            try store.archiveStale()
            #expect(try store.listTickets().map(\.id).sorted() == [old, fresh])
            #expect(try store.listTickets(archive: .excludingArchived).map(\.id) == [fresh])
            #expect(try store.listTickets(archive: .onlyArchived).map(\.id) == [old])
            #expect(try store.listTickets(statuses: [.waiting], archive: .onlyArchived).isEmpty)
        }
    }

    @Test func activityAndRestoreClearTheArchive() throws {
        try withStore { store, clock, _ in
            let id = try store.createTicket(title: "t", status: .active).id
            clock.advance(2 * day)
            try store.archiveStale()
            try store.touchActivity(id: id)
            #expect(try store.getTicket(id: id).archivedAt == nil)

            clock.advance(2 * day)
            try store.archiveStale()
            let restored = try store.restoreTicket(id: id)
            #expect(restored.archivedAt == nil && restored.kept)
            clock.advance(5 * day)
            #expect(try store.archiveStale() == 0)  // 되살린 티켓은 유지라 다시 보관되지 않는다
        }
    }

    @Test func aUserStatusChangeLeavesTheArchive() throws {
        try withStore { store, clock, _ in
            let id = try store.createTicket(title: "t", status: .active).id
            clock.advance(2 * day)
            try store.archiveStale()
            let done = try store.patchTicketAsUser(id: id, TicketPatch(status: .done))
            #expect(done.archivedAt == nil && done.status == .done && !done.kept)
        }
    }

    // MARK: auto done marker / done is never archived (schema v6)

    @Test func aUserStatusChangeClearsTheAutoDoneMarkerButOtherEditsDoNot() throws {
        try withStore { store, clock, _ in
            let id = try store.createTicket(title: "t", status: .active).id
            try store.patchTicket(id: id, TicketPatch(status: .done, autoDoneAt: .some(clock.current)))
            #expect(try store.getTicket(id: id).autoDoneAt == clock.current)
            // 제목/next_action 편집은 상태가 아니므로 표지가 남는다.
            try store.patchTicketAsUser(id: id, TicketPatch(nextAction: .some("later")))
            #expect(try store.getTicket(id: id).autoDoneAt == clock.current)
            // 사용자가 직접 done으로 닫으면(이미 자동 완료였어도) 표지가 지워진다: 이제 사용자가 닫은 티켓이다.
            try store.patchTicketAsUser(id: id, TicketPatch(status: .done))
            #expect(try store.getTicket(id: id).autoDoneAt == nil)
        }
    }

    @Test func doneNeverStaysArchivedWhicheverPathClosesTheTicket() throws {
        try withStore { store, clock, _ in
            let id = try store.createTicket(title: "t", status: .waiting).id
            clock.advance(2 * day)
            #expect(try store.archiveStale() == 1)
            // 훅/폴러가 쓰는 patchTicket도 done으로 바꾸면 보관을 푼다(폴러 자동 완료가 done+보관을 만들지 않는다).
            let done = try store.patchTicket(id: id, TicketPatch(status: .done))
            #expect(done.status == .done && done.archivedAt == nil)
        }
    }

    @Test func autoDoneAtRoundTripsThroughUpdateTicketAndJSON() throws {
        try withStore { store, clock, _ in
            let id = try store.createTicket(title: "t").id
            var ticket = try store.getTicket(id: id)
            ticket.autoDoneAt = clock.current
            ticket.status = .done
            let saved = try store.updateTicket(ticket)
            #expect(saved.autoDoneAt == clock.current)
            let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
            #expect(object["autoDoneAt"] != nil && !(object["autoDoneAt"] is NSNull))
            let plain = try store.createTicket(title: "plain")
            let plainObject = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
            #expect(plainObject["autoDoneAt"] is NSNull)
        }
    }

    @Test func newTicketsCanStartKept() throws {
        try withStore { store, clock, _ in
            let id = try store.createTicket(NewTicket(title: "mine", pinnedTitle: true, kept: true)).id
            clock.advance(10 * day)
            #expect(try store.archiveStale() == 0 && store.getTicket(id: id).kept)
        }
    }

    @Test func ticketJSONHasKeptAndArchivedAtWithExplicitNull() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "t")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(ticket)) as? [String: Any])
            #expect(object["kept"] as? Bool == false && object["archivedAt"] is NSNull)
        }
    }

    // MARK: ignore

    @Test func ignoreDeletesTheTicketAndRecordsSessionKeysButNotTheTab() throws {
        try withStore { store, clock, _ in
            let reconciler = Reconciler(store: store, projectResolver: NoProject())
            let id = try #require(try reconciler.apply(event: claudeEvent(.userPromptSubmit, prompt: "hi"), env: env(), now: clock.current)).ticketId
            try store.addLocation(
                ticketId: id, locator: .codexThread(.init(threadId: "c9")), source: .hook, externalKey: "codex:c9")

            let result = try store.ignoreTicket(id: id)
            #expect(Set(result.sessionKeys) == ["claude:s1", "codex:c9"] && result.tabIds == ["tab-1"])
            #expect(try store.listTickets().isEmpty && store.location(byExternalKey: "orca-tab:tab-1") == nil)
            let ignored = try store.ignoredSessions()
            #expect(Set(ignored.map(\.externalKey)) == ["claude:s1", "codex:c9"])  // orca-tab 키는 없다
            #expect(ignored.allSatisfy { $0.reason == "user-ignored" })

            // 같은 세션의 이후 이벤트는 버려진다.
            #expect(try reconciler.apply(event: claudeEvent(.stop), env: env(), now: clock.current) == nil)
            #expect(try store.listTickets().isEmpty)
            #expect(throws: StoreError.self) { try store.ignoreTicket(id: id) }
        }
    }

    @Test func aNewSessionInTheSameTabAppearsAsANewTicketAfterIgnore() throws {
        try withStore { store, clock, _ in
            let reconciler = Reconciler(store: store, projectResolver: NoProject())
            let id = try #require(try reconciler.apply(event: claudeEvent(.sessionStart), env: env(), now: clock.current)).ticketId
            try store.ignoreTicket(id: id)
            #expect(try store.ignoredOrcaTabs() == ["tab-1": 0])

            let outcome = try #require(try reconciler.apply(
                event: claudeEvent(.userPromptSubmit, session: "s2", prompt: "next task"), env: env(), now: clock.current))
            #expect(outcome.created)
            #expect(try store.location(byExternalKey: "orca-tab:tab-1")?.ticketId == outcome.ticketId)
            #expect(try store.ignoredOrcaTabs().isEmpty)  // 새 세션이 탭을 가져가면 폴러 쪽 표시는 풀린다
        }
    }

    // MARK: Reconciler

    @Test func anyEventForAnArchivedTicketBringsItBack() throws {
        for kind in [AgentEventKind.userPromptSubmit, .stop, .permissionRequest, .postToolUse, .sessionStart] {
            try withStore { store, clock, _ in
                let reconciler = Reconciler(store: store, projectResolver: NoProject())
                let id = try #require(try reconciler.apply(event: claudeEvent(.sessionStart), env: nil, now: clock.current)).ticketId
                clock.advance(2 * day)
                try store.archiveStale()
                #expect(try store.getTicket(id: id).archivedAt != nil)
                try reconciler.apply(event: claudeEvent(kind, prompt: "again"), env: nil, now: clock.current)
                #expect(try store.getTicket(id: id).archivedAt == nil, "\(kind)")
            }
        }
    }

    @Test func aKeptEmptyTicketIsNotDeletedWhenItLosesItsTab() throws {
        try withStore { store, clock, _ in
            let sync = OrcaSync(store: store)
            // 폴러가 만든 inbox 티켓을 사용자가 ⭐로 유지했다. 같은 탭에서 새 세션이 시작돼도 지워지면 안 된다.
            try sync.apply(snapshot([agent("tab-1", updated: clock.current)], [terminal("tab-1")]), now: clock.current)
            let inbox = try #require(try store.listTickets().first)
            try store.setKept(id: inbox.id, true)
            let reconciler = Reconciler(store: store, projectResolver: NoProject())
            // 입양 대상이 아니도록 오래 방치한 뒤 새 세션이 탭을 가져간다.
            clock.advance(2 * Reconciler.adoptWindow)
            try reconciler.apply(event: claudeEvent(.sessionStart), env: env(), now: clock.current)
            #expect(try store.getTicket(id: inbox.id).kept)
            #expect(try store.listTickets().count == 2)
        }
    }
}

@Suite struct CleanupSyncTests {
    private func hookTicket(_ store: Store, _ clock: TestClock, tab: String = "tab-1", handle: String = "term_1") throws -> Int64 {
        let reconciler = Reconciler(store: store, projectResolver: NoProject())
        return try #require(try reconciler.apply(event: claudeEvent(.sessionStart), env: env(tab: tab, handle: handle), now: clock.current)).ticketId
    }

    /// 두 번 연속 못 찾으면 사라진 탭이다.
    @discardableResult
    private func missTwice(_ sync: OrcaSync, _ clock: TestClock, _ snap: OrcaSnapshot? = nil) throws -> SyncSummary {
        try sync.apply(snap ?? otherTab, now: clock.current)
        clock.advance(30)
        return try sync.apply(snap ?? otherTab, now: clock.current)
    }

    // MARK: 자동 완료

    @Test func aGoneTabMarksAnUnkeptTicketDoneAfterTheTwoMissRuleAndShowsItAsRecentlyDone() throws {
        try withStore { store, clock, _ in
            let sync = OrcaSync(store: store)
            let id = try hookTicket(store, clock)
            clock.advance(3_600)
            let first = try sync.apply(otherTab, now: clock.current)
            #expect(first.gone == 0 && first.autoDone == 0)
            #expect(try store.getTicket(id: id).status == .active)  // 한 번 안 보인 것으로는 아직 아니다

            clock.advance(30)
            let second = try sync.apply(otherTab, now: clock.current)
            #expect(second.gone == 1 && second.autoDone == 1 && second.autoDoneTicketIds == [id])
            let ticket = try store.getTicket(id: id)
            #expect(ticket.status == .done && !ticket.kept)
            #expect(ticket.lastActivityAt == clock.current)  // 방금 끝난 일이라 "최근 완료"에 보인다
            // 세션 위치(재개 명령)는 남는다.
            #expect(try store.location(byExternalKey: "claude:s1")?.ticketId == id)
        }
    }

    @Test func aKeptTicketStaysWhenItsTabIsGone() throws {
        try withStore { store, clock, _ in
            let id = try hookTicket(store, clock)
            try store.setKept(id: id, true)
            let summary = try missTwice(OrcaSync(store: store), clock)
            #expect(summary.gone == 1 && summary.autoDone == 0)
            #expect(try store.getTicket(id: id).status == .active)
        }
    }

    @Test func aTicketWithAnotherLiveTerminalIsNotCompletedByOneGoneTab() throws {
        try withStore { store, clock, _ in
            let id = try hookTicket(store, clock)
            try store.addLocation(
                ticketId: id, locator: .orcaTerminal(.init(terminalHandle: "term_2", tabId: "tab-2")),
                source: .hook, externalKey: "orca-tab:tab-2")
            // tab-2는 계속 보이고 tab-1만 사라진다.
            let snap = snapshot([agent("tab-2", updated: clock.current)], [terminal("tab-2", handle: "term_2")])
            let summary = try missTwice(OrcaSync(store: store), clock, snap)
            #expect(summary.gone == 1 && summary.autoDone == 0)
            #expect(try store.getTicket(id: id).status == .active)

            // 이어서 tab-2도 사라지면 그때 마지막 살아 있는 탭이 사라진 것이다.
            let after = try missTwice(OrcaSync(store: store), clock)
            #expect(after.autoDone == 1)
            #expect(try store.getTicket(id: id).status == .done)
        }
    }

    @Test func sessionLocationsDoNotCountAsLiveSoCodexTicketsCanAutoComplete() throws {
        try withStore { store, clock, _ in
            let reconciler = Reconciler(store: store, projectResolver: NoProject())
            let event = AgentEvent(agent: .codex, kind: .userPromptSubmit, sessionId: "c1", cwd: cwd, prompt: "hi")
            let id = try #require(try reconciler.apply(event: event, env: env(), now: clock.current)).ticketId
            #expect(try missTwice(OrcaSync(store: store), clock).autoDone == 1)
            #expect(try store.getTicket(id: id).status == .done)
        }
    }

    @Test func aTicketAlreadyMarkedGoneBeforeThisFeatureIsSweptWithoutBumpingActivity() throws {
        try withStore { store, clock, _ in
            let id = try hookTicket(store, clock)
            let location = try #require(try store.location(byExternalKey: "orca-tab:tab-1"))
            try store.setLocationGone(id: location.id, at: clock.current)  // 이전 버전이 이미 표시해 둔 상태
            let started = clock.current
            clock.advance(3 * day)
            let summary = try OrcaSync(store: store).apply(otherTab, now: clock.current)
            #expect(summary.autoDone == 1 && summary.gone == 0)
            let ticket = try store.getTicket(id: id)
            #expect(ticket.status == .done && ticket.lastActivityAt == started)
        }
    }

    @Test func aTruncatedSnapshotNeverCompletesAnything() throws {
        try withStore { store, clock, _ in
            let id = try hookTicket(store, clock)
            let truncated = OrcaSnapshot(agents: [], terminals: [terminal("other", handle: "term_other")], truncated: true, droppedElements: 0)
            let summary = try missTwice(OrcaSync(store: store), clock, truncated)
            #expect(summary.gone == 0 && summary.autoDone == 0)
            #expect(try store.getTicket(id: id).status == .active)
        }
    }

    // MARK: 자동 보관

    @Test func syncArchivesStaleUnkeptTicketsAndReportsTheCount() throws {
        try withStore { store, clock, _ in
            let stale = try store.createTicket(title: "stale", status: .active).id
            let kept = try store.createTicket(NewTicket(title: "mine", status: .active, kept: true)).id
            clock.advance(day + 60)
            let summary = try OrcaSync(store: store).apply(snapshot(), now: clock.current)
            #expect(summary.archived == 1)
            #expect(try store.getTicket(id: stale).archivedAt == clock.current)
            #expect(try store.getTicket(id: kept).archivedAt == nil)
        }
    }

    @Test func anOldAgentTheSyncJustDiscoveredGoesStraightToTheArchive() throws {
        try withStore { store, clock, _ in
            let old = clock.current.addingTimeInterval(-3 * day)
            let summary = try OrcaSync(store: store).apply(snapshot([agent("tab-9", updated: old)], [terminal("tab-9")]), now: clock.current)
            #expect(summary.created == 1 && summary.archived == 1)
        }
    }

    @Test func previewDoesNotArchive() throws {
        try withStore { store, clock, _ in
            let id = try store.createTicket(title: "stale", status: .active).id
            clock.advance(2 * day)
            #expect(try OrcaSync(store: store).preview(snapshot(), now: clock.current).archived == 1)
            #expect(try store.getTicket(id: id).archivedAt == nil)
        }
    }

    // MARK: 무시와 폴러

    @Test func theSyncDoesNotRecreateAnIgnoredTicketWhileTheAgentIsStillListed() throws {
        try withStore { store, clock, _ in
            let sync = OrcaSync(store: store)
            let live = snapshot([agent("tab-1", updated: clock.current)], [terminal("tab-1")])
            #expect(try sync.apply(live, now: clock.current).created == 1)
            let id = try #require(try store.listTickets().first).id

            try store.ignoreTicket(id: id)
            for _ in 0..<3 {
                clock.advance(30)
                let summary = try sync.apply(live, now: clock.current)
                #expect(summary.created == 0 && summary.ignoredTabs == 1)
            }
            #expect(try store.listTickets().isEmpty)
        }
    }

    @Test func aNewHookSessionInAnIgnoredTabStillAppearsAndThePollerThenMergesIt() throws {
        try withStore { store, clock, _ in
            let sync = OrcaSync(store: store)
            let live = snapshot([agent("tab-1", updated: clock.current)], [terminal("tab-1")])
            _ = try hookTicket(store, clock)
            let first = try #require(try store.listTickets().first).id
            try store.ignoreTicket(id: first)
            try sync.apply(live, now: clock.current)
            #expect(try store.listTickets().isEmpty)

            let reconciler = Reconciler(store: store, projectResolver: NoProject())
            let outcome = try #require(try reconciler.apply(
                event: claudeEvent(.userPromptSubmit, session: "s2", prompt: "new"), env: env(), now: clock.current))
            #expect(outcome.created)
            clock.advance(30)
            let summary = try sync.apply(live, now: clock.current)
            #expect(summary.created == 0 && summary.ignoredTabs == 0)
            #expect(try store.listTickets().count == 1)
        }
    }

    @Test func theIgnoreMarkerClearsWhenTheTabDisappearsForTwoSyncs() throws {
        try withStore { store, clock, _ in
            let sync = OrcaSync(store: store)
            let live = snapshot([agent("tab-1", updated: clock.current)], [terminal("tab-1")])
            _ = try hookTicket(store, clock)
            try store.ignoreTicket(id: try #require(try store.listTickets().first).id)

            try sync.apply(otherTab, now: clock.current)
            #expect(try store.ignoredOrcaTabs() == ["tab-1": 1])
            clock.advance(30)
            try sync.apply(live, now: clock.current)  // 다시 보이면 횟수를 되돌린다
            #expect(try store.ignoredOrcaTabs() == ["tab-1": 0])
            for _ in 0..<2 { clock.advance(30); try sync.apply(otherTab, now: clock.current) }
            #expect(try store.ignoredOrcaTabs().isEmpty)
        }
    }

    @Test func aSnapshotThatCannotDetectGoneNeverClearsTheMarker() throws {
        try withStore { store, clock, _ in
            _ = try hookTicket(store, clock)
            try store.ignoreTicket(id: try #require(try store.listTickets().first).id)
            for _ in 0..<3 { try OrcaSync(store: store).apply(snapshot(), now: clock.current) }
            #expect(try store.ignoredOrcaTabs() == ["tab-1": 0])
        }
    }
}

// MARK: 자동 완료 재개방 (2026-10-01 결정), blocked 보호, 폴러 일관성

private func workingAgent(_ tab: String, updated: Date) -> OrcaSnapshot.Agent {
    .init(paneKey: "\(tab):leaf-1", state: "working", agentType: "claude", prompt: nil, updatedAt: updated,
          worktreeId: wtId, worktreePath: "/Users/me/Work/app-wt")
}

@Suite struct ReopenAutoDoneTests {
    private func reconciler(_ store: Store) -> Reconciler { Reconciler(store: store, projectResolver: NoProject()) }

    @discardableResult
    private func start(_ store: Store, _ clock: TestClock, env tabEnv: OrcaEnv? = nil) throws -> Int64 {
        try #require(try reconciler(store).apply(event: claudeEvent(.sessionStart), env: tabEnv, now: clock.current)).ticketId
    }

    @Test func sessionEndAutoDonesWithAMarkerAndTheSameSessionReopensIt() throws {
        for kind in [AgentEventKind.sessionStart, .userPromptSubmit] {
            try withStore { store, clock, _ in
                let id = try start(store, clock, env: env())
                clock.advance(600)
                try reconciler(store).apply(event: claudeEvent(.sessionEnd), env: env(), now: clock.current)
                let done = try store.getTicket(id: id)
                #expect(done.status == .done && done.autoDoneAt == clock.current && done.endedAt == clock.current)

                clock.advance(3_600)
                try reconciler(store).apply(event: claudeEvent(kind, prompt: "resume"), env: env(), now: clock.current)
                let reopened = try store.getTicket(id: id)
                #expect(reopened.status == .active && reopened.autoDoneAt == nil && reopened.endedAt == nil, "\(kind)")
                #expect(reopened.archivedAt == nil && reopened.waitingReason == nil)
                #expect(reopened.lastActivityAt == clock.current)
            }
        }
    }

    @Test func aReopenedTicketCountsAsWaitingAgainAndAutoDonesAgain() throws {
        try withStore { store, clock, _ in
            let id = try start(store, clock)
            try reconciler(store).apply(event: claudeEvent(.sessionEnd), env: nil, now: clock.current)
            try reconciler(store).apply(event: claudeEvent(.sessionStart), env: nil, now: clock.current)
            try reconciler(store).apply(event: claudeEvent(.permissionRequest), env: nil, now: clock.current)
            let waiting = try store.getTicket(id: id)
            #expect(waiting.status == .waiting && waiting.waitingReason == .permission)  // 배지에 센다
            try reconciler(store).apply(event: claudeEvent(.sessionEnd), env: nil, now: clock.current)
            let again = try store.getTicket(id: id)
            #expect(again.status == .done && again.autoDoneAt != nil)
        }
    }

    @Test func aTicketTheUserClosedIsNeverReopened() throws {
        try withStore { store, clock, _ in
            let id = try start(store, clock)
            try store.patchTicketAsUser(id: id, TicketPatch(status: .done))
            for kind in [AgentEventKind.sessionStart, .userPromptSubmit, .stop, .permissionRequest] {
                try reconciler(store).apply(event: claudeEvent(kind, prompt: "again"), env: nil, now: clock.current)
            }
            #expect(try store.getTicket(id: id).status == .done)
        }
    }

    /// 자동 완료 뒤에 사용자가 ✓로 다시 닫으면(이미 done이어도) 표지가 지워져 더는 열리지 않는다.
    @Test func closingAnAutoDoneTicketByHandTakesOwnershipAway() throws {
        try withStore { store, clock, _ in
            let id = try start(store, clock)
            try reconciler(store).apply(event: claudeEvent(.sessionEnd), env: nil, now: clock.current)
            try store.patchTicketAsUser(id: id, TicketPatch(status: .done))
            try reconciler(store).apply(event: claudeEvent(.sessionStart), env: nil, now: clock.current)
            #expect(try store.getTicket(id: id).status == .done)
        }
    }

    @Test func onlyAFreshSessionStartOrPromptReopensNotLateStopOrPermissionOrToolEvents() throws {
        try withStore { store, clock, _ in
            let id = try start(store, clock)
            try reconciler(store).apply(event: claudeEvent(.sessionEnd), env: nil, now: clock.current)
            for kind in [AgentEventKind.stop, .stopFailure, .permissionRequest, .postToolUse] {
                try reconciler(store).apply(event: claudeEvent(kind), env: nil, now: clock.current)
                let ticket = try store.getTicket(id: id)
                #expect(ticket.status == .done && ticket.autoDoneAt != nil, "\(kind)")
            }
        }
    }

    @Test func aNoteOrNextActionEditKeepsTheMarkerSoTheTicketStillReopens() throws {
        try withStore { store, clock, _ in
            let id = try start(store, clock)
            try reconciler(store).apply(event: claudeEvent(.sessionEnd), env: nil, now: clock.current)
            try store.patchTicketAsUser(id: id, TicketPatch(nextAction: .some("check later")))
            try reconciler(store).apply(event: claudeEvent(.sessionStart), env: nil, now: clock.current)
            let ticket = try store.getTicket(id: id)
            #expect(ticket.status == .active && ticket.kept)
        }
    }

    @Test func blockedAndKeptTicketsAreNotAutoDoneBySessionEnd() throws {
        try withStore { store, clock, _ in
            let blocked = try start(store, clock)
            try store.patchTicketAsUser(id: blocked, TicketPatch(status: .blocked))
            try reconciler(store).apply(event: claudeEvent(.sessionEnd), env: nil, now: clock.current)
            let ticket = try store.getTicket(id: blocked)
            #expect(ticket.status == .blocked && ticket.autoDoneAt == nil && ticket.endedAt == clock.current)

            let kept = try #require(try reconciler(store).apply(
                event: claudeEvent(.sessionStart, session: "s2"), env: nil, now: clock.current)).ticketId
            try store.setKept(id: kept, true)
            try reconciler(store).apply(event: claudeEvent(.sessionEnd, session: "s2"), env: nil, now: clock.current)
            #expect(try store.getTicket(id: kept).status == .active)
        }
    }

    // MARK: Orca poller

    @Test func aPollerAutoDoneCarriesTheMarkerAndLeavesTheArchive() throws {
        try withStore { store, clock, _ in
            let id = try start(store, clock, env: env())
            // 보관된 뒤에 탭이 사라진다: done이면서 보관된 티켓이 남으면 안 된다(훅 경로는 "최근 완료"로 간다).
            clock.advance(2 * day)
            try store.archiveStale()
            #expect(try store.getTicket(id: id).archivedAt != nil)
            let sync = OrcaSync(store: store)
            try sync.apply(otherTab, now: clock.current)
            clock.advance(30)
            let summary = try sync.apply(otherTab, now: clock.current)
            #expect(summary.autoDone == 1)
            let done = try store.getTicket(id: id)
            #expect(done.status == .done && done.autoDoneAt == clock.current && done.archivedAt == nil)
        }
    }

    @Test func aBlockedTicketIsNotAutoDoneWhenItsTabIsGone() throws {
        try withStore { store, clock, _ in
            let id = try start(store, clock, env: env())
            try store.patchTicketAsUser(id: id, TicketPatch(status: .blocked))
            let sync = OrcaSync(store: store)
            try sync.apply(otherTab, now: clock.current)
            clock.advance(30)
            let summary = try sync.apply(otherTab, now: clock.current)
            #expect(summary.gone == 1 && summary.autoDone == 0)
            #expect(try store.getTicket(id: id).status == .blocked)
        }
    }

    @Test func aTabThatComesBackWithAWorkingAgentReopensAnAutoDoneTicket() throws {
        try withStore { store, clock, _ in
            let id = try start(store, clock, env: env())
            let sync = OrcaSync(store: store)
            try sync.apply(otherTab, now: clock.current)
            clock.advance(30)
            try sync.apply(otherTab, now: clock.current)
            #expect(try store.getTicket(id: id).status == .done)

            clock.advance(60)
            let back = snapshot([workingAgent("tab-1", updated: clock.current)], [terminal("tab-1")])
            let summary = try sync.apply(back, now: clock.current)
            #expect(summary.revived == 1 && summary.reopened == 1 && summary.reopenedTicketIds == [id])
            let ticket = try store.getTicket(id: id)
            #expect(ticket.status == .active && ticket.autoDoneAt == nil)
        }
    }

    /// 사용자가 닫은 티켓, 에이전트가 일하지 않는 돌아온 탭(Orca 재시작 뒤 떨어진 옛 탭)은 열지 않는다.
    @Test func theTabComingBackDoesNotReopenUserClosedOrIdleAgentTickets() throws {
        for userClosed in [true, false] {
            try withStore { store, clock, _ in
                let id = try start(store, clock, env: env())
                let sync = OrcaSync(store: store)
                try sync.apply(otherTab, now: clock.current)
                clock.advance(30)
                try sync.apply(otherTab, now: clock.current)
                if userClosed { try store.patchTicketAsUser(id: id, TicketPatch(status: .done)) }

                clock.advance(60)
                let idleAgent = snapshot([agent("tab-1", updated: clock.current)], [terminal("tab-1")])
                let working = snapshot([workingAgent("tab-1", updated: clock.current)], [terminal("tab-1")])
                let first = try sync.apply(userClosed ? working : idleAgent, now: clock.current)
                #expect(first.reopened == 0)
                #expect(try store.getTicket(id: id).status == .done, "userClosed=\(userClosed)")
            }
        }
    }

    // MARK: 무시 표시 만료 (N3)

    @Test func anOldIgnoredTabMarkerExpiresWhileTheTabIsStillOpen() throws {
        try withStore { store, clock, _ in
            try store.ignoreOrcaTab("tab-old")
            clock.advance(OrcaSync.ignoredTabExpiry / 2)
            try store.ignoreOrcaTab("tab-new")
            clock.advance(OrcaSync.ignoredTabExpiry / 2 + 1)
            // 탭이 계속 보이는 스냅샷에서도 오래된 표시는 만료된다.
            let live = snapshot([agent("tab-old", updated: clock.current), agent("tab-new", updated: clock.current)],
                                [terminal("tab-old", handle: "term_old"), terminal("tab-new", handle: "term_new")])
            try OrcaSync(store: store).apply(live, now: clock.current)
            #expect(try store.ignoredOrcaTabs().keys.sorted() == ["tab-new"])
        }
    }
}
