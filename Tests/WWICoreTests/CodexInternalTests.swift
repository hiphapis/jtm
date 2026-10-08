import Foundation
import Testing
@testable import WWICore

// Codex 내부 작업은 수집하지 않는다(docs/01-product/auto-capture.md). 기록 파일은 가짜 값으로 만든 합성 파일이다.

private struct NoProject: ProjectResolver {
    func gitTopLevel(containing cwd: String) -> String? { nil }
}

private let cwd = "/Users/me/Work/app"

/// 실측한 `session_meta` 첫 줄의 모양(키 이름과 값 종류)을 따르되 값은 모두 가짜다.
private func sessionMetaLine(source: String, threadSource: String?, padding: Int = 0) -> String {
    var payload = """
        "id":"00000000-0000-4000-8000-000000000001","cwd":"\(cwd)","originator":"Codex Desktop","source":\(source)
        """
    if let threadSource { payload += #","thread_source":"\#(threadSource)""# }
    if padding > 0 { payload += #","base_instructions":"\#(String(repeating: "x", count: padding))""# }
    return #"{"timestamp":"2026-01-01T00:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"# + payload + "}}"
}

private func withRollout<T>(_ firstLine: String?, extraLines: Int = 2, _ body: (String) throws -> T) throws -> T {
    let directory = NSTemporaryDirectory() + "wwi-rollout-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let path = directory + "/rollout-2026-01-01T00-00-00-00000000-0000-4000-8000-000000000001.jsonl"
    if let firstLine {
        let rest = (0..<extraLines).map { #"{"type":"event_msg","payload":{"type":"user_message","message":"line \#($0)"}}"# }
        try (([firstLine] + rest).joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
    return try body(path)
}

private func codexEvent(_ kind: AgentEventKind, session: String = "c1", path: String?, prompt: String? = nil) -> AgentEvent {
    AgentEvent(agent: .codex, kind: kind, sessionId: session, cwd: cwd, prompt: prompt, transcriptPath: path)
}

private func withReconciler(_ body: (Reconciler, Store, TestClock) throws -> Void) throws {
    try withStore { store, clock, _ in
        try body(Reconciler(store: store, projectResolver: NoProject()), store, clock)
    }
}

/// `#expect`의 자동 클로저 안에서 `try`가 겹치면 컴파일이 막히는 경우가 있어, 값은 먼저 구해서 비교한다.
private func apply(_ reconciler: Reconciler, _ event: AgentEvent, _ clock: TestClock) throws -> Reconciler.Outcome? {
    try reconciler.apply(event: event, env: nil, now: clock.current)
}

private func ignoredKeys(_ store: Store) throws -> [String] { try store.ignoredSessions().map(\.externalKey) }

@Suite struct CodexInternalTests {
    // MARK: 첫 줄 해석

    @Test(arguments: [
        (#""cli""#, "user" as String?, false),
        (#""vscode""#, "chatgpt_handoff", false),
        (#""vscode""#, nil, false),
        (#""cli""#, "guardian_review", true),
        (#"{"subagent":{"other":"guardian"}}"#, "guardian_review", true),
        (#"{"subagent":{"other":"review"}}"#, nil, true),
        (#""subagent""#, "user", true),
    ])
    func sessionMetaClassifiesInternalWork(source: String, threadSource: String?, isInternal: Bool) throws {
        try withRollout(sessionMetaLine(source: source, threadSource: threadSource)) { path in
            guard case .meta(let meta) = FileCodexTranscriptReader().probe(path: path) else {
                Issue.record("not parsed"); return
            }
            #expect(meta.isInternal == isInternal, "\(source) \(threadSource ?? "-")")
        }
    }

    @Test func aMissingFileIsMissingAndGarbageIsUnknown() throws {
        let reader = FileCodexTranscriptReader()
        #expect(reader.probe(path: "/Users/me/does-not-exist/rollout.jsonl") == .missing)
        #expect(reader.probe(path: "relative/rollout.jsonl") == .unknown)
        try withRollout("not json at all") { #expect(reader.probe(path: $0) == .unknown) }
        try withRollout(#"{"type":"event_msg","payload":{}}"#) { #expect(reader.probe(path: $0) == .unknown) }
    }

    @Test func aDirectoryOrAnEmptyFileIsUnknownNotMissing() throws {
        let reader = FileCodexTranscriptReader()
        try withRollout(nil) { path in
            #expect(reader.probe(path: (path as NSString).deletingLastPathComponent) == .unknown)
            FileManager.default.createFile(atPath: path, contents: Data())
            #expect(reader.probe(path: path) == .unknown)
        }
    }

    @Test func onlyTheFirstLineUpTo64KBIsRead() throws {
        // 첫 줄이 20KB(실측 15~23KB)여도 읽고, 뒤의 줄은 보지 않는다.
        let line = sessionMetaLine(source: #"{"subagent":{"other":"guardian"}}"#, threadSource: "guardian_review", padding: 20_000)
        try withRollout(line, extraLines: 5) { path in
            #expect(FileCodexTranscriptReader().probe(path: path) == .meta(CodexSessionMeta(source: "subagent", threadSource: "guardian_review")))
        }
        // 64KB를 넘는 첫 줄은 해석하지 못하고 보수적으로 수집한다(unknown).
        let huge = sessionMetaLine(source: #""cli""#, threadSource: "user", padding: 70_000)
        try withRollout(huge) { #expect(FileCodexTranscriptReader().probe(path: $0) == .unknown) }
    }

    @Test func aFifoIsNeverBlockedOn() throws {
        let path = NSTemporaryDirectory() + "wwi-fifo-\(UUID().uuidString)"
        #expect(mkfifo(path, 0o600) == 0)
        defer { unlink(path) }
        #expect(FileCodexTranscriptReader().probe(path: path) == .unknown)
    }

    // MARK: Reconciler

    @Test func guardianAndSubagentSessionsAreIgnoredAndRecorded() throws {
        for (source, thread) in [(#"{"subagent":{"other":"guardian"}}"#, "guardian_review"), (#""cli""#, "guardian_review")] {
            try withRollout(sessionMetaLine(source: source, threadSource: thread)) { path in
                try withReconciler { reconciler, store, clock in
                    let outcome = try reconciler.apply(
                        event: codexEvent(.userPromptSubmit, path: path, prompt: "review this"), env: nil, now: clock.current)
                    #expect(outcome == nil)
                    #expect(try store.listTickets().isEmpty)
                    do { let keys = try ignoredKeys(store); #expect(keys == ["codex:c1"]) }
                    #expect(try store.ignoredSessions().first?.reason == "codex-internal")
                    // 이후 이벤트는 파일을 다시 읽지 않아도 버려진다.
                    for kind in [AgentEventKind.sessionStart, .stop, .permissionRequest, .postToolUse] {
                        do { let result = try apply(reconciler, codexEvent(kind, path: path), clock); #expect(result == nil) }
                    }
                    #expect(try store.listTickets().isEmpty)
                }
            }
        }
    }

    @Test(arguments: ["user", "chatgpt_handoff"])
    func userSessionsAreCollected(threadSource: String) throws {
        try withRollout(sessionMetaLine(source: #""vscode""#, threadSource: threadSource)) { path in
            try withReconciler { reconciler, store, clock in
                let outcome = try reconciler.apply(
                    event: codexEvent(.userPromptSubmit, path: path, prompt: "fix the build"), env: nil, now: clock.current)
                #expect(outcome?.created == true)
                #expect(try store.listTickets().map(\.title) == ["fix the build"])
                do { let keys = try ignoredKeys(store); #expect(keys.isEmpty) }
            }
        }
    }

    @Test func aMissingThreadSourceIsCollectedConservatively() throws {
        try withRollout(sessionMetaLine(source: #""vscode""#, threadSource: nil)) { path in
            try withReconciler { reconciler, store, clock in
                do { let result = try apply(reconciler, codexEvent(.userPromptSubmit, path: path, prompt: "hi"), clock); #expect(result?.created == true) }
                do { let keys = try ignoredKeys(store); #expect(keys.isEmpty) }
            }
        }
    }

    /// 기록 파일이 없는 첫 프롬프트는 영구 무시가 아니다: 티켓도 무시 기록도 없이 보류하고 다음 이벤트에서 다시 판단한다.
    @Test func aPromptWithoutARolloutFileIsUndecidedNotIgnored() throws {
        try withReconciler { reconciler, store, clock in
            let path = "/Users/me/.codex/sessions/2026/01/01/rollout-never-written.jsonl"
            let outcome = try reconciler.apply(
                event: codexEvent(.userPromptSubmit, path: path, prompt: "# Overview Generate 0 to 3 suggestions"),
                env: nil, now: clock.current)
            #expect(outcome == nil)
            #expect(try store.listTickets().isEmpty)
            do { let keys = try ignoredKeys(store); #expect(keys.isEmpty) }
            #expect(try store.codexUndecided("codex:c1")?.firstSeen == clock.current)
        }
    }

    /// 일회성 내부 작업은 파일이 끝내 안 생긴다: 유예 시간이 지난 뒤의 이벤트에서야 `codex-internal-nofile`로 무시한다.
    @Test func aRolloutThatNeverAppearsIsIgnoredOnlyAfterTheGracePeriod() throws {
        try withReconciler { reconciler, store, clock in
            let path = "/Users/me/.codex/sessions/2026/01/01/rollout-never-written.jsonl"
            _ = try apply(reconciler, codexEvent(.userPromptSubmit, path: path, prompt: "internal job"), clock)
            clock.advance(Reconciler.missingRolloutGrace - 1)
            _ = try apply(reconciler, codexEvent(.stop, path: path), clock)
            do { let keys = try ignoredKeys(store); #expect(keys.isEmpty) }
            clock.advance(2)
            let late = try apply(reconciler, codexEvent(.postToolUse, path: path), clock)
            #expect(try late == nil && store.listTickets().isEmpty)
            do { let keys = try ignoredKeys(store); #expect(keys == ["codex:c1"]) }
            #expect(try store.ignoredSessions().first?.reason == "codex-internal-nofile")
            #expect(try store.codexUndecided("codex:c1") == nil)
            // 이후 이벤트는 파일이 계속 없으면 버려진다.
            let after = try apply(reconciler, codexEvent(.userPromptSubmit, path: path, prompt: "again"), clock)
            #expect(try after == nil && store.listTickets().isEmpty)
        }
    }

    /// 사용자 세션인데 첫 프롬프트 때 파일이 아직 없던 경우(S1): 파일이 생기면 수집하고, 보류 중에 본 첫 프롬프트 제목을 이어받는다.
    @Test func aUserSessionWhoseFileAppearsLaterIsCollectedWithTheFirstPromptAsTitle() throws {
        try withRollout(nil) { path in
            try withReconciler { reconciler, store, clock in
                _ = try apply(reconciler, codexEvent(.userPromptSubmit, path: path, prompt: "Fix the flaky login test"), clock)
                #expect(try store.listTickets().isEmpty)
                try (sessionMetaLine(source: #""cli""#, threadSource: "user") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                clock.advance(2)
                let outcome = try apply(reconciler, codexEvent(.stop, path: path), clock)
                #expect(outcome?.created == true)
                let ticket = try #require(try store.listTickets().first)
                #expect(ticket.title == "Fix the flaky login test" && ticket.status == .waiting)
                #expect(try store.codexUndecided("codex:c1") == nil)
                do { let keys = try ignoredKeys(store); #expect(keys.isEmpty) }
            }
        }
    }

    /// `codex-internal-nofile`로 잘못 무시된 세션도 파일이 생기면 스스로 풀려 수집된다. 파일이 내부 작업이면 `codex-internal`로 확정한다.
    @Test func aNoFileIgnoreHealsWhenAUserFileAppearsAndIsConfirmedWhenItIsInternal() throws {
        for internalFile in [false, true] {
            try withRollout(nil) { path in
                try withReconciler { reconciler, store, clock in
                    _ = try apply(reconciler, codexEvent(.userPromptSubmit, path: path, prompt: "hello"), clock)
                    clock.advance(Reconciler.missingRolloutGrace + 1)
                    _ = try apply(reconciler, codexEvent(.stop, path: path), clock)
                    #expect(try store.ignoredSessionReason("codex:c1") == "codex-internal-nofile")

                    let line = internalFile
                        ? sessionMetaLine(source: #"{"subagent":{"other":"guardian"}}"#, threadSource: "guardian_review")
                        : sessionMetaLine(source: #""cli""#, threadSource: "user")
                    try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                    let outcome = try apply(reconciler, codexEvent(.userPromptSubmit, path: path, prompt: "hello again"), clock)
                    if internalFile {
                        #expect(try outcome == nil && store.listTickets().isEmpty)
                        #expect(try store.ignoredSessionReason("codex:c1") == "codex-internal")
                    } else {
                        #expect(outcome?.created == true)
                        #expect(try store.ignoredSessionReason("codex:c1") == nil && !store.isSessionIgnored("codex:c1"))
                    }
                }
            }
        }
    }

    /// 사용자가 직접 무시한 세션이나 확실한 증거로 무시한 세션은 파일이 있어도 풀리지 않는다.
    @Test func otherIgnoreReasonsNeverHeal() throws {
        try withRollout(sessionMetaLine(source: #""cli""#, threadSource: "user")) { path in
            try withReconciler { reconciler, store, clock in
                try store.ignoreSession("codex:c1", reason: "user-ignored")
                let outcome = try apply(reconciler, codexEvent(.userPromptSubmit, path: path, prompt: "hello"), clock)
                #expect(try outcome == nil && store.listTickets().isEmpty)
                #expect(try store.isSessionIgnored("codex:c1"))
            }
        }
    }

    @Test func staleUndecidedNotesAreSweptWhenANewOneIsWritten() throws {
        try withStore { store, clock, _ in
            try store.noteCodexUndecided("codex:old", title: "old")
            clock.advance(Store.codexUndecidedKeep + 1)
            try store.noteCodexUndecided("codex:new", title: nil)
            #expect(try store.codexUndecided("codex:old") == nil)
            #expect(try store.codexUndecided("codex:new")?.title == nil)
            // 같은 세션을 다시 봐도 처음 시각을 유지하고, 비어 있던 제목만 채운다.
            let first = try #require(try store.codexUndecided("codex:new")).firstSeen
            clock.advance(5)
            let again = try store.noteCodexUndecided("codex:new", title: "later title")
            #expect(again.firstSeen == first && again.title == "later title")
        }
    }

    @Test func sessionStartWithoutAFileDecidesNothingAndALaterEventDecides() throws {
        try withRollout(nil) { path in
            try withReconciler { reconciler, store, clock in
                // SessionStart: 파일이 아직 없다 → 티켓도 무시 기록도 없다.
                do { let result = try apply(reconciler, codexEvent(.sessionStart, path: path), clock); #expect(result == nil) }
                #expect(try store.listTickets().isEmpty && store.ignoredSessions().isEmpty)
                // 다른 이벤트도 같다(파일이 없다는 이유만으로는 무시하지 않는다).
                do { let result = try apply(reconciler, codexEvent(.stop, path: path), clock); #expect(result == nil) }
                #expect(try store.listTickets().isEmpty && store.ignoredSessions().isEmpty)

                // 파일이 생긴 뒤 첫 프롬프트: 사용자 세션이라 수집한다.
                try (sessionMetaLine(source: #""cli""#, threadSource: "user") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                let outcome = try reconciler.apply(event: codexEvent(.userPromptSubmit, path: path, prompt: "hello"), env: nil, now: clock.current)
                #expect(outcome?.created == true)
            }
        }
    }

    @Test func aSessionStartWithAFileForAnInternalSessionIsIgnoredImmediately() throws {
        try withRollout(sessionMetaLine(source: #"{"subagent":{"other":"guardian"}}"#, threadSource: "guardian_review")) { path in
            try withReconciler { reconciler, store, clock in
                do { let result = try apply(reconciler, codexEvent(.sessionStart, path: path), clock); #expect(result == nil) }
                do { let keys = try ignoredKeys(store); #expect(keys == ["codex:c1"]) }
            }
        }
    }

    @Test func noTranscriptPathMeansCollect() throws {
        try withReconciler { reconciler, store, clock in
            do { let result = try apply(reconciler, codexEvent(.sessionStart, path: nil), clock); #expect(result?.created == true) }
            do { let keys = try ignoredKeys(store); #expect(keys.isEmpty) }
        }
    }

    @Test func claudeEventsNeverReadATranscript() throws {
        try withReconciler { reconciler, store, clock in
            let event = AgentEvent(
                agent: .claude, kind: .userPromptSubmit, sessionId: "k1", cwd: cwd, prompt: "hi",
                transcriptPath: "/Users/me/.claude/projects/x/k1.jsonl")  // 없는 파일이어도 Claude는 무시하지 않는다
            do { let result = try apply(reconciler, event, clock); #expect(result?.created == true) }
        }
    }

    @Test func anExistingTicketIsNotReprobed() throws {
        // 이미 티켓이 있는 세션은 이벤트마다 파일을 읽지 않는다(여기서는 파일이 사라져도 계속 수집한다).
        try withRollout(sessionMetaLine(source: #""cli""#, threadSource: "user")) { path in
            try withReconciler { reconciler, store, clock in
                _ = try reconciler.apply(event: codexEvent(.userPromptSubmit, path: path, prompt: "hello"), env: nil, now: clock.current)
                try FileManager.default.removeItem(atPath: path)
                do { let result = try apply(reconciler, codexEvent(.stop, path: path), clock); #expect(result?.created == false) }
                #expect(try store.listTickets().first?.status == .waiting)
                do { let keys = try ignoredKeys(store); #expect(keys.isEmpty) }
            }
        }
    }

    @Test func eventParsingCarriesTheTranscriptPath() throws {
        let json = #"{"hook_event_name":"UserPromptSubmit","session_id":"c1","cwd":"/Users/me/Work/app","transcript_path":"/Users/me/x.jsonl","prompt":"hi"}"#
        let event = try #require(try AgentEvent.parse(agent: .codex, json: Data(json.utf8)))
        #expect(event.transcriptPath == "/Users/me/x.jsonl")
        let none = try #require(try AgentEvent.parse(agent: .codex, json: Data(#"{"hook_event_name":"Stop","session_id":"c1","transcript_path":""}"#.utf8)))
        #expect(none.transcriptPath == nil)
    }

    /// 실제 `wwi ingest` 프로세스: 내부 세션은 DB에 티켓을 남기지 않고, 사용자 세션은 남긴다.
    @Test func processLevelIngestIgnoresInternalSessions() throws {
        let directory = NSTemporaryDirectory() + "wwi-codex-internal-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let db = directory + "/jtm.sqlite"
        let guardian = directory + "/guardian.jsonl"
        let user = directory + "/user.jsonl"
        try (sessionMetaLine(source: #"{"subagent":{"other":"guardian"}}"#, threadSource: "guardian_review") + "\n")
            .write(toFile: guardian, atomically: true, encoding: .utf8)
        try (sessionMetaLine(source: #""cli""#, threadSource: "user") + "\n").write(toFile: user, atomically: true, encoding: .utf8)
        func payload(_ session: String, _ path: String) -> Data {
            Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(session)","cwd":"\#(cwd)","transcript_path":"\#(path)","prompt":"hello"}"#.utf8)
        }
        #expect(wwi(["ingest", "codex"], db: db, environment: ["WWI_LOG_PATH": directory + "/log"], stdin: payload("g1", guardian)).status == 0)
        #expect(wwi(["ingest", "codex"], db: db, environment: ["WWI_LOG_PATH": directory + "/log"], stdin: payload("u1", user)).status == 0)
        #expect(wwi(["ingest", "codex"], db: db, environment: ["WWI_LOG_PATH": directory + "/log"], stdin: payload("n1", directory + "/missing.jsonl")).status == 0)
        let listed = wwi(["ls", "--all", "--json"], db: db).array ?? []
        #expect(listed.count == 1)
        let store = try Store(path: db)
        // 파일이 없는 n1은 영구 무시가 아니라 보류다(티켓도 무시 기록도 없다).
        #expect(Set(try store.ignoredSessions().map(\.externalKey)) == ["codex:g1"])
        #expect(try store.codexUndecided("codex:n1") != nil)
    }
}
