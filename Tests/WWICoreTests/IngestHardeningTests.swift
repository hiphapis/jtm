import Foundation
import SQLite3
import Testing
@testable import WWICore

// 훅이 절대 오래 붙잡히지 않는다는 보장과 파일 권한 등 `wwi ingest`의 하드닝 테스트.
// 실제 `wwi` 바이너리를 띄운다. DB와 로그는 테스트마다 고유한 임시 경로다.

private struct Paths {
    var directory: String
    var db: String { directory + "/data/jtm.sqlite" }
    var log: String { directory + "/logs/ingest.log" }
}

private func withPaths<T>(_ body: (Paths) throws -> T) throws -> T {
    let directory = NSTemporaryDirectory() + "wwi-hardening-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: directory) }
    return try body(Paths(directory: directory))
}

private let startEvent = #"{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/Users/me/Work/app"}"#

@discardableResult
private func ingest(
    _ paths: Paths, _ payload: String, agent: String = "claude", environment: [String: String] = [:]
) -> CLIResult {
    wwi(["ingest", agent], db: paths.db, environment: environment.merging(["WWI_LOG_PATH": paths.log]) { $1 }, stdin: Data(payload.utf8))
}

private func logLines(_ paths: Paths) -> [String] {
    ((try? String(contentsOfFile: paths.log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

private func mode(_ path: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
}

private func ticketCount(_ paths: Paths) -> Int {
    (wwi(["ls", "--all", "--json"], db: paths.db).array ?? []).count
}

/// stdin을 끝까지 열어 둔 채로 `wwi ingest`를 실행하고, 끝날 때까지 걸린 시간과 종료 코드를 돌려준다.
private func runIngestKeepingStdinOpen(
    _ paths: Paths, payload: String, environment: [String: String] = [:], patience: TimeInterval = 8
) throws -> (status: Int32, elapsed: TimeInterval, stdout: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: wwiExecutable())
    process.arguments = ["ingest", "claude"]
    var env = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(), "WWI_DB_PATH": paths.db, "WWI_LOG_PATH": paths.log]
    env.merge(environment) { $1 }
    process.environment = env
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let started = Date()
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))  // 쓰기만 하고 닫지 않는다: EOF가 오지 않는다
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    if process.isRunning == false { exited.signal() }
    let finished = exited.wait(timeout: .now() + patience) == .success
    let elapsed = Date().timeIntervalSince(started)
    if !finished { process.terminate() }
    process.waitUntilExit()
    try? input.fileHandleForWriting.close()
    #expect(finished, "ingest was still running after \(patience)s")
    return (process.terminationStatus, elapsed, output.fileHandleForReading.readDataToEndOfFile())
}

@Suite struct IngestTimeLimitTests {
    /// 페이로드는 왔는데 EOF가 안 오는 경우: 계속 기다리지 않고 받은 것으로 처리한 뒤 3초 안에 exit 0.
    @Test func stdinThatNeverReachesEOFStillFinishesWithinAboutThreeSeconds() throws {
        try withPaths { paths in
            let result = try runIngestKeepingStdinOpen(paths, payload: startEvent)
            #expect(result.status == 0 && result.stdout.isEmpty)
            #expect(result.elapsed < 3.0, "took \(result.elapsed)s")
            #expect(ticketCount(paths) == 1)  // 온전한 JSON이었으니 반영됐다
            #expect(logLines(paths).isEmpty)
        }
    }

    @Test func aTruncatedPayloadWithoutEOFIsLoggedNotApplied() throws {
        try withPaths { paths in
            let result = try runIngestKeepingStdinOpen(paths, payload: #"{"hook_event_name":"Sess"#)
            #expect(result.status == 0 && result.elapsed < 3.0)
            #expect(logLines(paths).count == 1 && !FileManager.default.fileExists(atPath: paths.db))
        }
    }

    /// 워치독 자체: stdin 읽기 제한(1.5초)보다 먼저(0.3초) 프로세스를 exit 0으로 끝낸다. 기본값 2.5초는 같은 코드 경로다.
    /// stdin 대기가 끝나기 전에 죽었으므로 받은 이벤트는 반영되지 않았다(= 정상 종료가 아니라 워치독이 끝냈다는 증거).
    @Test func theWatchdogEndsAHungIngestWithExitZero() throws {
        try withPaths { paths in
            let result = try runIngestKeepingStdinOpen(
                paths, payload: startEvent, environment: ["WWI_INGEST_WATCHDOG_MS": "300"])
            #expect(result.status == 0 && result.stdout.isEmpty)
            #expect(result.elapsed >= 0.25 && result.elapsed < 1.2, "took \(result.elapsed)s")
            #expect(!FileManager.default.fileExists(atPath: paths.db) && logLines(paths).isEmpty)
        }
    }

    /// 읽는 쪽이 없는 FIFO가 로그 경로이면 `open`이 영원히 막힌다. `O_NONBLOCK`으로 열어서 곧바로 실패하고 넘어간다.
    @Test func aLogPathThatIsAFIFOWithoutAReaderDoesNotBlock() throws {
        try withPaths { paths in
            try FileManager.default.createDirectory(atPath: paths.directory, withIntermediateDirectories: true)
            let fifo = paths.directory + "/ingest.fifo"
            #expect(mkfifo(fifo, 0o600) == 0)
            let started = Date()
            let result = wwi(
                ["ingest", "claude"], db: paths.db, environment: ["WWI_LOG_PATH": fifo], stdin: Data("not json".utf8))
            #expect(result.status == 0 && result.stdout.isEmpty)
            #expect(Date().timeIntervalSince(started) < 3.0, "took \(Date().timeIntervalSince(started))s")
        }
    }

    @Test func aDatabaseLockedByAnotherConnectionEndsWithinTheHookBudget() throws {
        try withPaths { paths in
            // 롤백 저널 모드의 DB를 만들고 읽기 트랜잭션을 붙잡아 WAL 전환을 막는다(리뷰에서 12초 걸리던 경우).
            try FileManager.default.createDirectory(atPath: paths.directory + "/data", withIntermediateDirectories: true)
            var db: OpaquePointer?
            #expect(sqlite3_open(paths.db, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            #expect(sqlite3_exec(db, "CREATE TABLE t(x); INSERT INTO t VALUES (1); BEGIN; SELECT * FROM t;", nil, nil, nil) == SQLITE_OK)
            let started = Date()
            let result = ingest(paths, startEvent)
            let elapsed = Date().timeIntervalSince(started)
            #expect(result.status == 0 && result.stdout.isEmpty)
            #expect(elapsed < 3.0, "took \(elapsed)s")
        }
    }
}

@Suite struct IngestArgumentTests {
    @Test(arguments: [
        [] as [String], ["--bogus"], ["-x", "--y"], ["gemini"], ["gemini", "extra", "args"],
    ])
    func badArgumentsNeverFailTheHook(arguments: [String]) throws {
        try withPaths { paths in
            let result = wwi(
                ["ingest"] + arguments, db: paths.db, environment: ["WWI_LOG_PATH": paths.log], stdin: Data(startEvent.utf8))
            #expect(result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty, "\(arguments): \(result.stderr)")
            #expect(logLines(paths).count == 1, "\(arguments)")
            #expect(!FileManager.default.fileExists(atPath: paths.db))
        }
    }

    /// 옵션처럼 보이는 인자가 섞여도 에이전트 이름이 있으면 처리한다.
    @Test func unknownOptionsAroundTheAgentAreIgnored() throws {
        try withPaths { paths in
            let result = wwi(
                ["ingest", "-x", "claude", "--y"], db: paths.db, environment: ["WWI_LOG_PATH": paths.log], stdin: Data(startEvent.utf8))
            #expect(result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty)
            #expect(logLines(paths).isEmpty && ticketCount(paths) == 1)
        }
    }

    /// 설치된 명령이 셸 없이 argv로 실행되어도(`# wwi-managed`가 인자로 남아도) 이벤트는 정상 처리된다.
    @Test func trailingMarkerArgumentsAreIgnored() throws {
        try withPaths { paths in
            let result = wwi(
                ["ingest", "claude", "#", "wwi-managed"], db: paths.db, environment: ["WWI_LOG_PATH": paths.log],
                stdin: Data(startEvent.utf8))
            #expect(result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty)
            #expect(logLines(paths).isEmpty && ticketCount(paths) == 1)
        }
    }

    @Test func helpStillWorks() throws {
        try withPaths { paths in
            let result = wwi(["ingest", "--help"], db: paths.db)
            #expect(result.status == 0 && result.stdout.contains("USAGE") && result.stdout.contains("ingest"))
            #expect(!FileManager.default.fileExists(atPath: paths.db))
        }
    }
}

@Suite struct IngestNoSideEffectTests {
    /// N3: 파싱해서 무시할 입력은 DB 파일도, WAL/SHM도, 마이그레이션도 만들지 않는다.
    @Test func ignoredOrUnparsableInputNeverTouchesTheDatabase() throws {
        try withPaths { paths in
            for payload in [
                "", "not json", "[1]", #"{"hook_event_name":"Notification","session_id":"s"}"#,
                #"{"hook_event_name":"PreToolUse","session_id":"s"}"#, #"{"session_id":"s"}"#,
                #"{"hook_event_name":"Stop"}"#,
            ] {
                let result = ingest(paths, payload)
                #expect(result.status == 0 && result.stdout.isEmpty)
            }
            #expect(!FileManager.default.fileExists(atPath: paths.db))
            #expect(!FileManager.default.fileExists(atPath: paths.directory + "/data"))
        }
    }

    /// S6: 헤드리스 Claude(`claude -p`)의 이벤트는 로그도 DB도 남기지 않는다. 대화형(`cli`)과 표지 없음은 처리한다.
    @Test func headlessClaudeEventsLeaveNoTrace() throws {
        try withPaths { paths in
            let orca = ["ORCA_TAB_ID": "tab-1", "ORCA_TERMINAL_HANDLE": "term_1"]
            for entrypoint in ["sdk-cli", "sdk-ts"] {
                let result = ingest(paths, startEvent, environment: orca.merging(["CLAUDE_CODE_ENTRYPOINT": entrypoint]) { $1 })
                #expect(result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty)
            }
            #expect(!FileManager.default.fileExists(atPath: paths.db) && logLines(paths).isEmpty)

            ingest(paths, startEvent, environment: orca.merging(["CLAUDE_CODE_ENTRYPOINT": "cli"]) { $1 })
            #expect(ticketCount(paths) == 1)
            // 표지가 없어도(예전 버전, 다른 실행 환경) 처리한다.
            ingest(paths, #"{"hook_event_name":"SessionStart","session_id":"s2"}"#, environment: orca)
            #expect(ticketCount(paths) == 2)
        }
    }

    /// Codex는 표지를 확정하지 못해서 걸러내지 않는다(환경변수가 있어도 처리).
    @Test func codexIsNotFilteredByTheClaudeEntrypoint() throws {
        try withPaths { paths in
            ingest(paths, startEvent, agent: "codex", environment: ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli"])
            #expect(ticketCount(paths) == 1)
        }
    }

    /// N2: 1MiB를 넘는 페이로드(큰 PostToolUse 응답 등)도 8MiB까지는 처리한다. 그 위는 로그만 남는다.
    @Test func payloadsUpToEightMebibytesAreProcessed() throws {
        try withPaths { paths in
            let filler = String(repeating: "x", count: 3 * 1_048_576)
            ingest(paths, #"{"hook_event_name":"UserPromptSubmit","session_id":"big","cwd":"/w","prompt":"big prompt","pad":"\#(filler)"}"#)
            #expect(logLines(paths).isEmpty && ticketCount(paths) == 1)

            let tooLarge = String(repeating: "y", count: Ingest.inputLimit)
            let result = ingest(paths, #"{"hook_event_name":"Stop","session_id":"big","pad":"\#(tooLarge)"}"#)
            #expect(result.status == 0 && result.stdout.isEmpty)
            #expect(logLines(paths).count == 1 && logLines(paths)[0].contains("payload larger than"))
        }
    }

    @Test func newEventsWorkThroughTheBinary() throws {
        try withPaths { paths in
            ingest(paths, #"{"hook_event_name":"PermissionRequest","session_id":"e1","cwd":"/w"}"#)
            func status() -> (String?, String?) {
                let ticket = wwi(["show", "1", "--json"], db: paths.db).object
                return (ticket?["status"] as? String, ticket?["waitingReason"] as? String)
            }
            #expect(status() == ("waiting", "permission"))
            ingest(paths, #"{"hook_event_name":"PostToolUse","session_id":"e1","cwd":"/w","tool_name":"Write"}"#)
            #expect(status() == ("active", nil))
            ingest(paths, #"{"hook_event_name":"StopFailure","session_id":"e1","cwd":"/w"}"#)
            #expect(status() == ("waiting", "error"))
            ingest(paths, #"{"hook_event_name":"PostToolUse","session_id":"e1","cwd":"/w"}"#)
            #expect(status() == ("waiting", "error"))  // permission 대기가 아니면 활동만 갱신한다
            ingest(paths, #"{"hook_event_name":"StopFailure","session_id":"c1","cwd":"/w"}"#, agent: "codex")
            #expect(ticketCount(paths) == 1)  // Codex에는 StopFailure가 없다
            #expect(logLines(paths).isEmpty)
        }
    }
}

@Suite struct FilePermissionTests {
    /// N6: 새로 만드는 DB 폴더는 0700, DB와 로그 파일은 0600(WAL/SHM은 본 파일의 권한을 따른다).
    @Test func newDatabaseAndLogFilesAreOwnerOnly() throws {
        try withPaths { paths in
            ingest(paths, startEvent)
            ingest(paths, "not json")  // 로그를 남긴다
            #expect(mode(paths.directory + "/data") == 0o700)
            #expect(mode(paths.db) == 0o600)
            #expect(mode(paths.directory + "/logs") == 0o700)
            #expect(mode(paths.log) == 0o600)
            for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: paths.db + suffix) {
                #expect(mode(paths.db + suffix) == 0o600, Comment(rawValue: suffix))
            }
        }
    }

    /// 이전 버전이 0644로 만든 DB와 로그는 다음 실행에서 조인다. 이미 있던 폴더의 권한은 바꾸지 않는다.
    @Test func looseExistingFilesAreTightenedButExistingDirectoriesAreLeftAlone() throws {
        try withPaths { paths in
            for folder in ["data", "logs"] {
                try FileManager.default.createDirectory(
                    atPath: paths.directory + "/" + folder, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o755])
            }
            _ = try Store(path: paths.db)
            chmodForTest(paths.db, 0o644)
            FileManager.default.createFile(atPath: paths.log, contents: Data("old\n".utf8), attributes: [.posixPermissions: 0o644])
            ingest(paths, startEvent)
            ingest(paths, "not json")
            #expect(mode(paths.db) == 0o600 && mode(paths.log) == 0o600)
            #expect(mode(paths.directory + "/data") == 0o755 && mode(paths.directory + "/logs") == 0o755)
            #expect(logLines(paths).first == "old")
        }
    }
}

private func chmodForTest(_ path: String, _ mode: mode_t) {
    _ = chmod(path, mode)
}
