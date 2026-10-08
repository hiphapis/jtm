import Foundation
import Testing
@testable import WWICore

// 실제 `wwi sync orca` 프로세스. Orca는 가짜 실행 파일(ORCA_CLI_COMMAND)이 픽스처를 출력한다: 실제 Orca는 호출하지 않는다.

func fixturePath(_ name: String) -> String {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)").path
}

/// `worktree ps`/`terminal list`에 픽스처를 그대로 돌려주고, 그 밖의 명령(쓰기 명령 포함)은 호출 기록을 남기고 실패하는 가짜 orca.
/// `workerHandle`이 있으면 최근에 바뀐 실행 기록 하나가 그 handle의 워커를 가진 것으로 답한다(없으면 실행 기록이 비어 있다).
/// mode `runlistdown`은 `orchestration run-list`만 실패한다.
func withFakeOrca<T>(
    mode: String = "ok", workerHandle: String? = nil, _ body: (_ orca: String, _ db: String, _ calls: String) throws -> T
) throws -> T {
    let updated = ISO8601DateFormatter().string(from: Date())
    let runs = workerHandle == nil ? "" : #"{"id":"run_1","updated_at":"\#(updated)"}"#
    let workers = workerHandle.map { #"{"dispatchId":"d","taskId":"t","runId":"run_1","agentTerminalHandle":"\#($0)","resource":null}"# } ?? ""
    let directory = NSTemporaryDirectory() + "wwi-sync-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let script = directory + "/orca"
    let calls = directory + "/calls.log"
    let body1 = """
        #!/bin/sh
        echo "$@" >> '\(calls)'
        case "\(mode)" in
          down) echo "Orca is not running" >&2; exit 1 ;;
          badjson) echo "not json"; exit 0 ;;
        esac
        case "$1 $2" in
          "worktree ps") cat '\(fixturePath("orca-worktree-ps.json"))' ;;
          "terminal list") cat '\(fixturePath("orca-terminal-list.json"))' ;;
          "orchestration run-list")
            if [ "\(mode)" = runlistdown ]; then echo "orchestration unavailable" >&2; exit 1; fi
            echo '{"ok":true,"result":{"runs":[\(runs)],"nextCursor":null}}' ;;
          "orchestration worker-list")
            echo '{"ok":true,"result":{"workers":[\(workers)],"page":{"hasMore":false,"nextCursor":null}}}' ;;
          *) echo "unexpected write/unknown command: $@" >&2; exit 2 ;;
        esac
        """
    try body1.write(toFile: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
    return try body(script, directory + "/jtm.sqlite", calls)
}

// 픽스처의 활동 시각은 고정돼 있어서 24시간이 지나면 동기화가 바로 보관함으로 보낸다. 개수는 `ls --all`(보관함 포함)로 센다.
@Suite struct SyncCLITests {
    @Test func syncCreatesInboxTicketsThenASecondRunCreatesNone() throws {
        try withFakeOrca { orca, db, calls in
            let first = wwi(["sync", "orca", "--json"], db: db, environment: ["ORCA_CLI_COMMAND": orca])
            #expect(first.status == 0 && first.stderr.isEmpty)
            let summary = first.object?["summary"] as? [String: Any]
            #expect(first.object?["ok"] as? Bool == true && first.object?["dryRun"] as? Bool == false)
            #expect(summary?["created"] as? Int == 4 && summary?["updated"] as? Int == 0)
            #expect(summary?["stale"] as? Int == 0 && summary?["gone"] as? Int == 0 && summary?["skipped"] as? Int == 7)
            #expect((summary?["createdTicketIds"] as? [Int]) == [1, 2, 3, 4])

            let listed = wwi(["ls", "--json", "--all"], db: db).array ?? []
            #expect(listed.count == 4 && listed.allSatisfy { $0["status"] as? String == "inbox" })
            #expect(listed.allSatisfy { ($0["title"] as? String)?.hasPrefix("Synthetic session title") == true })

            let second = wwi(["sync", "orca"], db: db, environment: ["ORCA_CLI_COMMAND": orca])
            #expect(second.status == 0 && second.stdout == "created 0, updated 0, stale 0, gone 0, skipped 7 (no terminal)\n")
            #expect((wwi(["ls", "--json", "--all"], db: db).array ?? []).count == 4)

            // 읽기 전용 명령만 호출했다.
            let log = (try? String(contentsOfFile: calls, encoding: .utf8)) ?? ""
            let commands = Set(log.split(separator: "\n").map { $0.split(separator: " ").prefix(2).joined(separator: " ") })
            #expect(commands == ["worktree ps", "terminal list", "orchestration run-list"])
            // 워커 handle 조회는 5분에 한 번이라 두 번째 sync는 다시 부르지 않는다.
            #expect(log.split(separator: "\n").filter { $0.hasPrefix("orchestration run-list") }.count == 1)
        }
    }

    @Test func dryRunPrintsTheSummaryAndWritesNothing() throws {
        try withFakeOrca { orca, db, _ in
            let result = wwi(["sync", "orca", "--dry-run"], db: db, environment: ["ORCA_CLI_COMMAND": orca])
            #expect(result.status == 0 && result.stdout.hasPrefix("dry run: created 4, "))
            #expect((wwi(["ls", "--all", "--json"], db: db).array ?? []).isEmpty)
            let json = wwi(["sync", "orca", "--dry-run", "--json"], db: db, environment: ["ORCA_CLI_COMMAND": orca])
            #expect(json.object?["dryRun"] as? Bool == true)
            #expect((wwi(["ls", "--all", "--json"], db: db).array ?? []).isEmpty)
        }
    }

    /// N14: 아직 DB가 없을 때 --dry-run은 DB 파일도 폴더도 WAL/SHM도 만들지 않는다(계산은 임시 메모리 DB에서).
    @Test func dryRunNeverCreatesTheDatabaseFile() throws {
        try withFakeOrca { orca, _, _ in
            let root = NSTemporaryDirectory() + "wwi-dry-\(UUID().uuidString)"
            defer { try? FileManager.default.removeItem(atPath: root) }
            let db = root + "/nested/jtm.sqlite"
            for flags in [["--dry-run"], ["--dry-run", "--json"]] {
                let result = wwi(["sync", "orca"] + flags, db: db, environment: ["ORCA_CLI_COMMAND": orca])
                #expect(result.status == 0 && result.stderr.isEmpty, "\(result.stderr)")
                #expect(result.stdout.contains("created 4") || result.stdout.contains("\"created\" : 4"), "\(result.stdout)")
                #expect(!FileManager.default.fileExists(atPath: root), "dry-run created \(root)")
            }
            // 실제 sync는 만든다.
            #expect(wwi(["sync", "orca"], db: db, environment: ["ORCA_CLI_COMMAND": orca]).status == 0)
            #expect(FileManager.default.fileExists(atPath: db))
        }
    }

    @Test(arguments: ["down", "badjson"])
    func unreachableOrBrokenOrcaFailsWithAMessageAndWritesNothing(mode: String) throws {
        try withFakeOrca(mode: mode) { orca, db, _ in
            let result = wwi(["sync", "orca"], db: db, environment: ["ORCA_CLI_COMMAND": orca])
            #expect(result.status != 0 && result.stdout.isEmpty)
            #expect(result.stderr.contains("orca worktree ps"), "\(result.stderr)")
            #expect(!FileManager.default.fileExists(atPath: db))  // DB를 열지도 않았다

            let json = wwi(["sync", "orca", "--json"], db: db, environment: ["ORCA_CLI_COMMAND": orca])
            #expect(json.status != 0 && json.object?["ok"] as? Bool == false)
        }
    }

    @Test func missingOrcaExecutableFailsCleanly() throws {
        try withFakeOrca { _, db, _ in
            let result = wwi(["sync", "orca"], db: db, environment: ["ORCA_CLI_COMMAND": "/nonexistent/orca"])
            #expect(result.status != 0 && !result.stderr.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: db))
        }
    }

    @Test func hookTicketIsEnrichedNotDuplicatedAndLsShowsTheFilledInTitle() throws {
        try withFakeOrca { orca, db, _ in
            // 픽스처의 첫 에이전트 탭에서 훅이 먼저 티켓을 만든 상황.
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixturePath("orca-worktree-ps.json")))) as? [String: Any]
            let worktrees = (fixture?["result"] as? [String: Any])?["worktrees"] as? [[String: Any]] ?? []
            let paneKey = try #require((worktrees.first?["agents"] as? [[String: Any]])?.first?["paneKey"] as? String)
            let tab = String(paneKey.split(separator: ":")[0])
            let hook = wwi(["ingest", "claude"], db: db, environment: [
                "ORCA_TAB_ID": tab, "ORCA_TERMINAL_HANDLE": "term_stale", "WWI_LOG_PATH": db + ".log"],
                stdin: Data(#"{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/w/app"}"#.utf8))
            #expect(hook.status == 0)

            let sync = wwi(["sync", "orca", "--json"], db: db, environment: ["ORCA_CLI_COMMAND": orca])
            let summary = sync.object?["summary"] as? [String: Any]
            #expect(summary?["created"] as? Int == 3 && summary?["updated"] as? Int == 1)
            let listed = wwi(["ls", "--json", "--all"], db: db).array ?? []
            #expect(listed.count == 4)
            let hooked = try #require(listed.first { ($0["locations"] as? [[String: Any]])?.contains { $0["externalKey"] as? String == "claude:s1" } == true })
            let locations = hooked["locations"] as? [[String: Any]] ?? []
            let tabLocation = try #require(locations.first { $0["externalKey"] as? String == "orca-tab:\(tab)" })
            #expect(tabLocation["source"] as? String == "hook")
            #expect((tabLocation["locator"] as? [String: Any])?["terminalHandle"] as? String != "term_stale")
        }
    }

    // MARK: 오케스트레이션 워커

    /// 픽스처에서 에이전트가 있는 탭 하나와 그 탭의 터미널 handle.
    private func fixtureAgentTab() throws -> (tab: String, handle: String) {
        let ps = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixturePath("orca-worktree-ps.json")))) as? [String: Any]
        let worktrees = (ps?["result"] as? [String: Any])?["worktrees"] as? [[String: Any]] ?? []
        let paneKey = try #require((worktrees.first?["agents"] as? [[String: Any]])?.first?["paneKey"] as? String)
        let tab = String(paneKey.split(separator: ":")[0])
        let list = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixturePath("orca-terminal-list.json")))) as? [String: Any]
        let terminals = (list?["result"] as? [String: Any])?["terminals"] as? [[String: Any]] ?? []
        let handle = try #require(terminals.first { $0["tabId"] as? String == tab }?["handle"] as? String)
        return (tab, handle)
    }

    @Test func syncSkipsWorkerTerminalsAndReadsWorkerHandlesOnlyOncePerFiveMinutes() throws {
        let target = try fixtureAgentTab()
        try withFakeOrca(workerHandle: target.handle) { orca, db, calls in
            let first = wwi(["sync", "orca", "--json"], db: db, environment: ["ORCA_CLI_COMMAND": orca])
            #expect(first.status == 0 && first.stderr.isEmpty)
            let summary = first.object?["summary"] as? [String: Any]
            #expect(summary?["created"] as? Int == 3 && summary?["workersIgnored"] as? Int == 1)
            let refresh = summary?["workerRefresh"] as? [String: Any]
            #expect(refresh?["runs"] as? Int == 1 && refresh?["handles"] as? Int == 1)
            let listed = wwi(["ls", "--json", "--all"], db: db).array ?? []
            #expect(listed.count == 3)

            let second = wwi(["sync", "orca"], db: db, environment: ["ORCA_CLI_COMMAND": orca])
            #expect(second.stdout == "created 0, updated 0, stale 0, gone 0, skipped 7 (no terminal), workers ignored 1\n")
            let log = (try? String(contentsOfFile: calls, encoding: .utf8)) ?? ""
            #expect(log.split(separator: "\n").filter { $0.hasPrefix("orchestration") }.map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
                == ["orchestration run-list", "orchestration worker-list"])

            // 워커 터미널에서 오는 훅 이벤트는 (프롬프트에 표지가 없어도) 티켓을 만들지 않는다.
            let hook = wwi(["ingest", "claude"], db: db, environment: [
                "ORCA_TAB_ID": target.tab, "ORCA_TERMINAL_HANDLE": target.handle, "WWI_LOG_PATH": db + ".log"],
                stdin: Data(#"{"hook_event_name":"SessionStart","session_id":"w1","cwd":"/w/app"}"#.utf8))
            #expect(hook.status == 0 && hook.stdout.isEmpty)
            #expect((wwi(["ls", "--json", "--all"], db: db).array ?? []).count == 3)
            #expect(!FileManager.default.fileExists(atPath: db + ".log"))
        }
    }

    @Test func aFailingWorkerRefreshDoesNotFailTheSyncAndIsReportedInTheSummary() throws {
        try withFakeOrca(mode: "runlistdown") { orca, db, _ in
            let json = wwi(["sync", "orca", "--json"], db: db, environment: ["ORCA_CLI_COMMAND": orca])
            #expect(json.status == 0 && json.stderr.isEmpty)
            let summary = json.object?["summary"] as? [String: Any]
            #expect(summary?["created"] as? Int == 4)
            #expect(((summary?["workerRefresh"] as? [String: Any])?["error"] as? String)?.contains("orca orchestration run-list") == true)
        }
        try withFakeOrca(mode: "runlistdown") { orca, db, _ in
            let text = wwi(["sync", "orca"], db: db, environment: ["ORCA_CLI_COMMAND": orca])
            #expect(text.status == 0 && text.stdout.contains("created 4") && text.stdout.contains("worker refresh failed"))
        }
    }

    @Test func dryRunReadsWorkerHandlesButRecordsNothing() throws {
        let target = try fixtureAgentTab()
        try withFakeOrca(workerHandle: target.handle) { orca, db, calls in
            for _ in 0..<2 {
                let result = wwi(["sync", "orca", "--dry-run"], db: db, environment: ["ORCA_CLI_COMMAND": orca])
                #expect(result.status == 0 && result.stdout.contains("workers ignored 1"), "\(result.stdout)")
            }
            let log = (try? String(contentsOfFile: calls, encoding: .utf8)) ?? ""
            #expect(log.split(separator: "\n").filter { $0.hasPrefix("orchestration run-list") }.count == 2)  // 시각을 남기지 않아서 매번 조회한다
            #expect(!FileManager.default.fileExists(atPath: db))
        }
    }
}
