import Foundation
import Testing
@testable import JTMCore

// 실제 `jtm ingest` 프로세스를 띄우는 테스트. DB와 로그는 테스트마다 고유한 임시 경로다.

private struct IngestEnv {
    var db: String
    var log: String
}

private func withIngestEnv<T>(_ body: (IngestEnv) throws -> T) throws -> T {
    let directory = NSTemporaryDirectory() + "jtm-ingest-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: directory) }
    return try body(IngestEnv(db: directory + "/jtm.sqlite", log: directory + "/logs/ingest.log"))
}

@discardableResult
private func ingest(
    _ agent: String, _ payload: Data, _ env: IngestEnv, environment: [String: String] = [:]
) -> CLIResult {
    jtm(["ingest", agent], db: env.db, environment: environment.merging(["JTM_LOG_PATH": env.log]) { $1 }, stdin: payload)
}

@discardableResult
private func ingest(_ agent: String, _ json: String, _ env: IngestEnv, environment: [String: String] = [:]) -> CLIResult {
    ingest(agent, Data(json.utf8), env, environment: environment)
}

private func logLines(_ env: IngestEnv) -> [String] {
    ((try? String(contentsOfFile: env.log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

private func tickets(_ env: IngestEnv) -> [[String: Any]] {
    jtm(["ls", "--all", "--json"], db: env.db).array ?? []
}

/// 프로세스를 띄우며 블로킹하는 작업을 전용 스레드로 병렬 실행한다. `concurrentPerform`은 GCD 풀을 점유해서
/// 같은 풀을 쓰는 다른 테스트(ProcessRunner의 파이프 리더)를 굶기므로 쓰지 않는다.
private func runInParallel(_ count: Int, _ body: @escaping @Sendable (Int) -> Void) {
    let group = DispatchGroup()
    for index in 0..<count {
        group.enter()
        Thread.detachNewThread {
            body(index)
            group.leave()
        }
    }
    group.wait()
}

@Suite struct IngestCLITests {
    @Test func validEventWritesATicketAndNothingElse() throws {
        try withIngestEnv { env in
            let result = ingest(
                "claude", #"{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/Users/me/app"}"#, env,
                environment: ["ORCA_TAB_ID": "tab-1", "ORCA_TERMINAL_HANDLE": "term_1", "ORCA_WORKTREE_ID": "uuid::/Users/me/app-wt"])
            #expect(result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty)
            #expect(logLines(env).isEmpty)
            let listed = tickets(env)
            #expect(listed.count == 1)
            #expect(listed[0]["title"] as? String == "claude session")
            #expect(listed[0]["status"] as? String == "active")
            #expect(listed[0]["project"] as? String == "app-wt")
            #expect(listed[0]["waitingReason"] is NSNull && listed[0]["endedAt"] is NSNull)
            let locations = listed[0]["locations"] as? [[String: Any]] ?? []
            #expect(locations.compactMap { $0["externalKey"] as? String } == ["claude:s1", "orca-tab:tab-1"])
            #expect(locations.allSatisfy { $0["goneAt"] is NSNull })
        }
    }

    @Test func promptThenStopShowsWaitingTurnEndInLsAndJSON() throws {
        try withIngestEnv { env in
            ingest("codex", #"{"hook_event_name":"UserPromptSubmit","session_id":"t1","cwd":"/w/app","prompt":"Reply with pong"}"#, env)
            ingest("codex", #"{"hook_event_name":"Stop","session_id":"t1","cwd":"/w/app"}"#, env)
            let line = jtm(["ls"], db: env.db).stdout
            #expect(line.contains("waiting(turn_end)") && line.contains("Reply with pong") && line.contains("[app]"))
            let shown = jtm(["show", "1", "--json"], db: env.db).object
            #expect(shown?["waitingReason"] as? String == "turn_end")
            let locator = ((shown?["locations"] as? [[String: Any]])?.first?["locator"] as? [String: Any])
            #expect(locator?["threadId"] as? String == "t1" && locator?["cwd"] as? String == "/w/app")
        }
    }

    @Test func badInputAlwaysExitsZeroPrintsNothingAndIsLogged() throws {
        try withIngestEnv { env in
            let oversized = Data(repeating: 0x20, count: Ingest.inputLimit + 4096)
            let cases: [(agent: String, payload: Data)] = [
                ("claude", Data()), ("claude", Data("not json".utf8)), ("claude", Data("[1,2]".utf8)),
                ("claude", Data(#"{"hook_event_name":"Stop"}"#.utf8)),
                ("gemini", Data(#"{"hook_event_name":"Stop","session_id":"s"}"#.utf8)),
                ("claude", oversized),
            ]
            for (agent, payload) in cases {
                let result = ingest(agent, payload, env)
                #expect(result.status == 0 && result.stdout.isEmpty, "\(agent) \(payload.count) bytes: \(result.stderr)")
            }
            #expect(logLines(env).count == cases.count)
            #expect(logLines(env).allSatisfy { $0.contains(" claude ") || $0.contains(" gemini ") })
            #expect(tickets(env).isEmpty)
        }
    }

    @Test func unknownAgentArgumentAndMissingStdinNeverFailTheHook() throws {
        try withIngestEnv { env in
            let noStdin = jtm(["ingest", "claude"], db: env.db, environment: ["JTM_LOG_PATH": env.log])
            #expect(noStdin.status == 0 && noStdin.stdout.isEmpty)
            #expect(logLines(env).count == 1)
        }
    }

    @Test func unhandledEventsAreIgnoredWithoutALogLine() throws {
        try withIngestEnv { env in
            for json in [
                #"{"hook_event_name":"Notification","session_id":"s","notification_type":"permission_prompt"}"#,
                #"{"hook_event_name":"PreToolUse","session_id":"s"}"#,
                #"{"session_id":"s"}"#,
            ] {
                let result = ingest("claude", json, env)
                #expect(result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty)
            }
            ingest("codex", #"{"hook_event_name":"SessionEnd","session_id":"s"}"#, env)
            #expect(logLines(env).isEmpty && tickets(env).isEmpty)
        }
    }

    @Test func unreachableDatabaseStillExitsZeroAndLogs() throws {
        try withIngestEnv { env in
            let result = jtm(
                ["ingest", "claude"], db: "/dev/null/nope/jtm.sqlite", environment: ["JTM_LOG_PATH": env.log],
                stdin: Data(#"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/w"}"#.utf8))
            #expect(result.status == 0 && result.stdout.isEmpty)
            #expect(logLines(env).count == 1 && logLines(env)[0].contains(" SessionStart "))  // 파싱이 먼저라 이벤트 이름이 로그에 남는다
        }
    }

    @Test func missingCwdFallsBackToTheHookProcessDirectory() throws {
        try withIngestEnv { env in
            ingest("claude", #"{"hook_event_name":"SessionStart","session_id":"s"}"#, env)
            let locator = ((tickets(env).first?["locations"] as? [[String: Any]])?.first?["locator"] as? [String: Any])
            // 테스트 프로세스의 작업 디렉터리(절대 경로)가 들어간다.
            #expect((locator?["cwd"] as? String)?.hasPrefix("/") == true)
        }
    }

    // MARK: 실측 샘플 재생

    @Test func replayingTheSampleFileThroughTheBinaryMatchesTheReconcilerResult() throws {
        try withIngestEnv { env in
            let transcripts = (env.db as NSString).deletingLastPathComponent + "/transcripts"
            for sample in try materializeTranscripts(loadHookSamples(), in: transcripts) + syntheticSamples() {
                let result = ingest(sample.agent, sample.payload, env, environment: sample.env)
                #expect(result.status == 0 && result.stdout.isEmpty, "\(sample.agent) \(sample.event)")
            }
            #expect(logLines(env).isEmpty)

            let listed = tickets(env)
            #expect(listed.count == 3)
            let byKey = Dictionary(uniqueKeysWithValues: listed.compactMap { ticket -> (String, [String: Any])? in
                let keys = (ticket["locations"] as? [[String: Any]] ?? []).compactMap { $0["externalKey"] as? String }
                return keys.first { $0.hasPrefix("claude:") || $0.hasPrefix("codex:") }.map { ($0, ticket) }
            })
            let old = try #require(byKey["claude:891dc7a6-454b-44f5-8ad2-5998d41d8aa5"])
            #expect(old["status"] as? String == "done" && old["waitingReason"] is NSNull)  // SessionEnd로 자동 완료
            #expect(old["endedAt"] is String && (old["locations"] as? [[String: Any]])?.count == 1)
            let codex = try #require(byKey["codex:c4b7a3bd-0820-4189-86cb-2932b676123a"])
            #expect((codex["locations"] as? [[String: Any]])?.count == 2 && codex["endedAt"] is NSNull)
            #expect(codex["project"] as? String == "sample-project")
            let synthetic = try #require(byKey["claude:synthetic-session-0001"])
            #expect(synthetic["waitingReason"] as? String == "turn_end" && synthetic["title"] as? String == "synthetic prompt")
        }
    }

    // MARK: 동시성 / 시간

    /// 새 DB에 5개 세션의 이벤트 20개(SessionStart/Prompt/Stop/PermissionRequest × 5)를 동시에 던진다.
    @Test func twentyParallelIngestsForFiveSessionsYieldExactlyFiveTickets() throws {
        let failures = FailureCounter()
        for round in 0..<3 {
            try withIngestEnv { env in
                let events = ["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest"]
                let jobs = (0..<5).flatMap { session in events.map { (session, $0) } }.shuffled()
                runInParallel(jobs.count) { index in
                    let (session, name) = jobs[index]
                    let agent = session < 3 ? "claude" : "codex"
                    let json = #"{"hook_event_name":"\#(name)","session_id":"sess-\#(session)","cwd":"/w/app\#(session)","prompt":"task \#(session)"}"#
                    let result = ingest(agent, json, env, environment: [
                        "ORCA_TAB_ID": "tab-\(session)", "ORCA_TERMINAL_HANDLE": "term_\(session)",
                        "ORCA_WORKTREE_ID": "wt::/w/app\(session)"])
                    if result.status != 0 || !result.stdout.isEmpty { failures.add("round \(round) \(agent) \(name): \(result.stderr)") }
                }
                #expect(logLines(env).isEmpty, "round \(round): \(logLines(env).prefix(3))")
                let listed = tickets(env)
                #expect(listed.count == 5, "round \(round)")
                for ticket in listed {
                    let keys = (ticket["locations"] as? [[String: Any]] ?? []).compactMap { $0["externalKey"] as? String }
                    #expect(keys.count == 2 && keys.contains { $0.hasPrefix("orca-tab:") }, "round \(round): \(keys)")
                }
            }
        }
        #expect(failures.all.isEmpty, "\(failures.all.prefix(3))")
    }

    /// 같은 탭에서 세션 여럿이 동시에 시작해도 탭 위치는 정확히 한 티켓에 있고 티켓은 세션 수만큼이다.
    @Test func parallelSessionsInOneTabLeaveTheTabOnExactlyOneTicket() throws {
        try withIngestEnv { env in
            runInParallel(6) { session in
                ingest("claude", #"{"hook_event_name":"SessionStart","session_id":"x-\#(session)","cwd":"/w"}"#, env,
                       environment: ["ORCA_TAB_ID": "shared", "ORCA_TERMINAL_HANDLE": "term_s"])
            }
            #expect(logLines(env).isEmpty)
            let listed = tickets(env)
            #expect(listed.count == 6)
            let owners = listed.filter { ticket in
                (ticket["locations"] as? [[String: Any]] ?? []).contains { $0["externalKey"] as? String == "orca-tab:shared" }
            }
            #expect(owners.count == 1)
        }
    }

    /// 훅 예산(2초)의 여유 확인. 정밀 측정(p50/max)은 별도로 보고한다.
    @Test func eachIngestFinishesWellUnderTheTwoSecondBudget() throws {
        try withIngestEnv { env in
            ingest("claude", #"{"hook_event_name":"SessionStart","session_id":"warm","cwd":"/w"}"#, env)
            var worst: TimeInterval = 0
            for _ in 0..<10 {
                let started = Date()
                let result = ingest("claude", #"{"hook_event_name":"Stop","session_id":"warm","cwd":"/w"}"#, env)
                worst = max(worst, Date().timeIntervalSince(started))
                #expect(result.status == 0)
            }
            #expect(worst < 1.0, "slowest ingest took \(worst)s")
        }
    }

    // MARK: 오케스트레이션 워커

    private func jsonString(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    /// 워커 안내문(Claude는 감싼 형태, Codex는 그대로)이 첫 프롬프트로 오면 SessionStart로 생긴 티켓이 지워지고 이후 이벤트는 버려진다.
    @Test(arguments: [("claude", WorkerFixtures.claudePrompt), ("codex", WorkerFixtures.codexPrompt)])
    func aWorkerPromptRemovesTheTicketAndLaterEventsAreDropped(agent: String, prompt: String) throws {
        try withIngestEnv { env in
            let orcaEnv = ["ORCA_TAB_ID": "tab-1", "ORCA_TERMINAL_HANDLE": "term_1", "ORCA_WORKTREE_ID": "uuid::/Users/me/app-wt"]
            func send(_ event: String, prompt: String? = nil) throws {
                var payload: [String: Any] = ["hook_event_name": event, "session_id": "w1", "cwd": "/Users/me/app"]
                payload["prompt"] = prompt
                let result = ingest(agent, try jsonString(payload), env, environment: orcaEnv)
                #expect(result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty)
            }
            try send("SessionStart")
            #expect(tickets(env).count == 1)
            try send("UserPromptSubmit", prompt: prompt)
            #expect(tickets(env).isEmpty)
            for event in ["Stop", "PermissionRequest", "PostToolUse", "UserPromptSubmit"] { try send(event, prompt: "hello") }
            #expect(tickets(env).isEmpty)
            #expect(logLines(env).isEmpty)
        }
    }

    @Test func aPromptThatOnlyMentionsOrcaStillMakesATicket() throws {
        try withIngestEnv { env in
            let payload = try jsonString([
                "hook_event_name": "UserPromptSubmit", "session_id": "u1", "cwd": "/Users/me/app",
                "prompt": "Explain how a dispatched worker gets its task inside Orca",
            ])
            #expect(ingest("claude", payload, env).status == 0)
            #expect(tickets(env).count == 1)
        }
    }
}
