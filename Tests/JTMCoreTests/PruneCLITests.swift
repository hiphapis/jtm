import Foundation
import Testing
@testable import JTMCore

// 실제 `jtm prune workers` 프로세스. Orca는 SyncCLITests의 가짜 실행 파일이다: 실제 Orca는 호출하지 않는다.

@Suite struct PruneCLITests {
    /// 워커 안내문의 앞부분만 있는(표지 하나) 프롬프트로 쌓인 옛 티켓을 만든다: 지금 규칙으로는 걸러지지 않는 노이즈를 흉내 낸다.
    private func seedLegacyNoise(_ db: String, handle: String = "term_legacy") {
        let env = ["JTM_LOG_PATH": db + ".log"]
        func hook(_ json: String, tab: String, handle: String) {
            let result = jtm(["ingest", "claude"], db: db, environment: env.merging(["ORCA_TAB_ID": tab, "ORCA_TERMINAL_HANDLE": handle]) { $1 }, stdin: Data(json.utf8))
            precondition(result.status == 0)
        }
        hook(#"{"hook_event_name":"UserPromptSubmit","session_id":"old1","cwd":"/w/app","prompt":"You are working inside Orca, a multi-agent IDE. Do the thing."}"#, tab: "tab-1", handle: "term_x")
        hook(#"{"hook_event_name":"UserPromptSubmit","session_id":"old2","cwd":"/w/app","prompt":"Please carry out this task from my Orca coordinator: rename it"}"#, tab: "tab-2", handle: "term_y")
        hook(#"{"hook_event_name":"UserPromptSubmit","session_id":"mine","cwd":"/w/app","prompt":"Why is Orca slow today?"}"#, tab: "tab-3", handle: "term_z")
        hook(#"{"hook_event_name":"SessionStart","session_id":"viaHandle","cwd":"/w/app"}"#, tab: "tab-4", handle: handle)
    }

    @Test func pruneDryRunListsAndRealRunRemovesOnlyUntouchedWorkerTickets() throws {
        try withFakeOrca(workerHandle: "term_legacy") { orca, db, _ in
            seedLegacyNoise(db)
            #expect((jtm(["ls", "--json"], db: db).array ?? []).count == 4)
            let mine = try #require((jtm(["ls", "--json"], db: db).array ?? []).first { ($0["title"] as? String)?.hasPrefix("Why is Orca") == true })
            let touched = try #require((jtm(["ls", "--json"], db: db).array ?? []).first { ($0["title"] as? String)?.hasPrefix("Please carry out") == true })
            #expect(jtm(["set", "\(touched["id"] as? Int ?? 0)", "--next", "look"], db: db).status == 0)
            let environment = ["ORCA_CLI_COMMAND": orca]

            let dry = jtm(["prune", "workers", "--dry-run"], db: db, environment: environment)
            #expect(dry.status == 0 && dry.stderr.isEmpty, "\(dry.stderr)")
            #expect(dry.stdout.contains("would remove 2 worker ticket(s) (dry run)") && dry.stdout.contains("kept 1 touched"), "\(dry.stdout)")
            #expect(dry.stdout.contains("orca-worker-title") && dry.stdout.contains("orca-worker-handle"))
            #expect((jtm(["ls", "--json"], db: db).array ?? []).count == 4)  // 아무것도 지우지 않았다

            let real = jtm(["prune", "workers", "--json"], db: db, environment: environment)
            #expect(real.status == 0 && real.object?["ok"] as? Bool == true && real.object?["dryRun"] as? Bool == false)
            let removed = real.object?["removed"] as? [[String: Any]] ?? []
            #expect(removed.count == 2 && Set(removed.compactMap { $0["reason"] as? String }) == ["orca-worker-title", "orca-worker-handle"])
            let remaining = Set((jtm(["ls", "--json"], db: db).array ?? []).compactMap { $0["id"] as? Int })
            #expect(remaining == Set([mine["id"] as? Int ?? -1, touched["id"] as? Int ?? -2]))

            // 정리한 세션의 이후 훅 이벤트는 티켓을 되살리지 않는다.
            let hook = jtm(["ingest", "claude"], db: db, environment: ["ORCA_TAB_ID": "tab-1", "ORCA_TERMINAL_HANDLE": "term_x", "JTM_LOG_PATH": db + ".log"],
                           stdin: Data(#"{"hook_event_name":"Stop","session_id":"old1","cwd":"/w/app"}"#.utf8))
            #expect(hook.status == 0 && (jtm(["ls", "--json"], db: db).array ?? []).count == 2)

            let again = jtm(["prune", "workers"], db: db, environment: environment)
            #expect(again.stdout.contains("removed 0 worker ticket(s)"))
        }
    }

    @Test func pruneStillWorksByTitleWhenOrcaCannotBeReadAndSaysSo() throws {
        try withFakeOrca(mode: "down") { orca, db, _ in
            seedLegacyNoise(db)
            let result = jtm(["prune", "workers", "--dry-run"], db: db, environment: ["ORCA_CLI_COMMAND": orca])
            #expect(result.status == 0 && result.stdout.contains("would remove 2"), "\(result.stdout)")
            #expect(result.stderr.contains("worker refresh failed"))
        }
    }

    @Test func pruneDryRunNeverCreatesTheDatabase() throws {
        try withFakeOrca { orca, _, _ in
            let root = NSTemporaryDirectory() + "jtm-prune-\(UUID().uuidString)"
            defer { try? FileManager.default.removeItem(atPath: root) }
            let result = jtm(["prune", "workers", "--dry-run"], db: root + "/nested/jtm.sqlite", environment: ["ORCA_CLI_COMMAND": orca])
            #expect(result.status == 0 && result.stdout.contains("would remove 0"), "\(result.stdout)")
            #expect(!FileManager.default.fileExists(atPath: root))
        }
    }
}
