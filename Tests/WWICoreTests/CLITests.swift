import Foundation
import Testing
@testable import WWICore

// MARK: 실제 `wwi` 바이너리를 띄우는 CLI 테스트 (종료 코드, stdout/stderr, --json 형태)
// DB는 테스트마다 고유한 임시 경로이고 서브프로세스 환경변수로만 넘긴다.
// `go`는 --dry-run만 쓴다(실제 open/orca/pbcopy는 호출하지 않는다).

struct CLIResult {
    var status: Int32
    var stdout: String
    var stderr: String

    var json: Any? { try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) }
    var object: [String: Any]? { json as? [String: Any] }
    var array: [[String: Any]]? { json as? [[String: Any]] }
}

func wwiExecutable() -> String {
    // Tests/WWICoreTests/CLITests.swift → 패키지 루트 → .build/debug/wwi
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [".build/debug/wwi", ".build/release/wwi"].map { root.appendingPathComponent($0).path }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
}

func wwi(_ arguments: [String], db: String, environment: [String: String] = [:], stdin: Data? = nil) -> CLIResult {
    signal(SIGPIPE, SIG_IGN)  // 프로세스가 stdin을 다 읽기 전에 끝나도(예: 1MB 한도) 테스트가 죽지 않게
    let process = Process()
    process.executableURL = URL(fileURLWithPath: wwiExecutable())
    process.arguments = arguments
    var env = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(), "WWI_DB_PATH": db, "ORCA_CLI_COMMAND": orca]
    env.merge(environment) { $1 }
    process.environment = env
    let out = Pipe(), err = Pipe(), input = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = stdin == nil ? FileHandle.nullDevice : input
    do { try process.run() } catch {
        return CLIResult(status: -1, stdout: "", stderr: "cannot run \(wwiExecutable()): \(error)")
    }
    if let stdin {
        // 출력 파이프가 차서 막히는 일이 없도록 별도 스레드에서 쓴다. GCD 풀은 다른 테스트(ProcessRunner)가
        // 쓰는 스레드를 굶기지 않게 피하고 전용 스레드를 쓴다.
        let writer = input.fileHandleForWriting
        Thread.detachNewThread {
            try? writer.write(contentsOf: stdin)
            try? writer.close()
        }
    }
    // 출력이 작으니 순서대로 읽는다(concurrentPerform 안에서 부르므로 별도 스레드를 만들지 않는다).
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CLIResult(
        status: process.terminationStatus,
        stdout: String(decoding: outData, as: UTF8.self),
        stderr: String(decoding: errData, as: UTF8.self))
}

func withDatabase<T>(_ body: (String) throws -> T) throws -> T {
    let directory = NSTemporaryDirectory() + "wwi-cli-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: directory) }
    return try body(directory + "/jtm.sqlite")
}

@Suite struct CLIAddTests {
    @Test func binaryIsBuilt() {
        #expect(FileManager.default.isExecutableFile(atPath: wwiExecutable()), "run `swift build` first: \(wwiExecutable())")
    }

    @Test func addPrintsOnlyTheNewIdAndPinsTheTitle() throws {
        try withDatabase { db in
            let added = wwi(["add", "  Write spec  "], db: db)
            #expect(added.status == 0 && added.stdout == "1\n" && added.stderr.isEmpty)
            let shown = wwi(["show", "1", "--json"], db: db).object
            #expect(shown?["title"] as? String == "Write spec")
            #expect(shown?["pinnedTitle"] as? Bool == true)
            #expect(shown?["status"] as? String == "inbox")
        }
    }

    @Test func addAttachesUrlAndTerminalAsManualLocations() throws {
        try withDatabase { db in
            let url = "https://chatgpt.com/g/g-p-05cf98908aa74814b7b82b700520204d-sample-project/c/d79e1949-d0d9-4dee-8ec0-79e0d341b41c"
            #expect(wwi(["add", "chat", "--url", url, "--orca-terminal", "term_x", "--status", "active"], db: db).status == 0)
            let shown = wwi(["show", "1", "--json"], db: db).object
            let locations = shown?["locations"] as? [[String: Any]] ?? []
            #expect(locations.map { $0["kind"] as? String } == ["orca_terminal", "chatgpt_chat"])
            #expect(locations.allSatisfy { $0["source"] as? String == "manual" })
            let chat = locations.last?["locator"] as? [String: Any]
            #expect(chat?["chatId"] as? String == "d79e1949-d0d9-4dee-8ec0-79e0d341b41c")
        }
    }

    @Test(arguments: [["add", "   "], ["add", "t", "--url", ""], ["add", "t", "--url", "  "], ["add", "t", "--orca-terminal", ""]])
    func rejectsBlankInputWithUsageError(_ arguments: [String]) throws {
        try withDatabase { db in
            let result = wwi(arguments, db: db)
            #expect(result.status == 64)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("must not be empty"))
            #expect(wwi(["ls", "--all"], db: db).stdout.isEmpty)
        }
    }

    @Test func rejectedAddCreatesNoTicket() throws {
        try withDatabase { db in
            _ = wwi(["add", "t", "--url", ""], db: db)
            #expect(wwi(["ls", "--all", "--json"], db: db).array?.isEmpty == true)
        }
    }
}

@Suite struct CLIExitCodeTests {
    @Test func unknownIdIsRuntimeErrorOnStderrOnly() throws {
        try withDatabase { db in
            for arguments in [["show", "999"], ["done", "999"], ["set", "999", "--note", "x"], ["go", "999", "--dry-run"]] {
                let result = wwi(arguments, db: db)
                #expect(result.status == 1, "\(arguments)")
                #expect(result.stdout.isEmpty)
                #expect(result.stderr.contains("not found"))
            }
        }
    }

    @Test func badStatusAndMissingFieldsAreUsageErrors() throws {
        try withDatabase { db in
            _ = wwi(["add", "t"], db: db)
            #expect(wwi(["set", "1", "--status", "bogus"], db: db).status == 64)
            #expect(wwi(["add", "x", "--status", "bogus"], db: db).status == 64)
            #expect(wwi(["ls", "--status", "bogus"], db: db).status == 64)
            let none = wwi(["set", "1"], db: db)
            #expect(none.status == 64 && none.stderr.contains("바꿀 필드"))
            #expect(wwi(["set", "1", "--priority", "high"], db: db).status == 64)
            #expect(wwi(["set", "1", "--title", " "], db: db).status == 64)
            #expect(wwi(["set", "1", "--title", "x", "--unpin-title"], db: db).status == 64)
        }
    }

    @Test func goWithoutLocationsFailsAndWrongLocationIsRejected() throws {
        try withDatabase { db in
            _ = wwi(["add", "bare"], db: db)
            _ = wwi(["add", "other", "--url", "https://example.com"], db: db)
            let none = wwi(["go", "1", "--dry-run"], db: db)
            #expect(none.status == 1 && none.stderr.contains("no locations"))
            let wrong = wwi(["go", "1", "--dry-run", "--location", "1"], db: db)
            #expect(wrong.status == 1 && wrong.stderr.contains("does not belong"))
        }
    }

    @Test func unwritableDatabasePathFailsCleanly() {
        let result = wwi(["ls"], db: "/dev/null/nope/jtm.sqlite")
        #expect(result.status == 1)
        #expect(result.stderr.contains("Error"))
    }
}

@Suite struct CLIJSONContractTests {
    @Test func optionalFieldsAreExplicitNull() throws {
        try withDatabase { db in
            _ = wwi(["add", "t", "--url", "https://example.com"], db: db)
            let listed = wwi(["ls", "--json"], db: db)
            let ticket = try #require(listed.array?.first)
            for key in ["priority", "project", "nextAction", "note"] {
                #expect(ticket[key] is NSNull, "\(key) should be null, got \(String(describing: ticket[key]))")
            }
            let location = try #require((ticket["locations"] as? [[String: Any]])?.first)
            #expect(location["externalKey"] is NSNull)
            #expect(Set(ticket.keys).isSuperset(of: [
                "id", "title", "status", "priority", "project", "nextAction", "note", "pinnedTitle",
                "createdAt", "updatedAt", "lastActivityAt", "locations",
            ]))
        }
    }

    @Test func emptyListIsAnEmptyArray() throws {
        try withDatabase { db in
            let result = wwi(["ls", "--json"], db: db)
            #expect(result.status == 0 && result.array?.isEmpty == true)
        }
    }

    @Test func errorsUnderJSONProduceOkFalseEnvelopeAndNonZeroExit() throws {
        try withDatabase { db in
            _ = wwi(["add", "bare"], db: db)
            let cases: [(args: [String], status: Int32)] = [
                (["show", "999", "--json"], 1),
                (["go", "999", "--dry-run", "--json"], 1),
                (["go", "1", "--json"], 1),
                (["ls", "--json", "--status", "bogus"], 64),
                (["add", "", "--json"], 64),
            ]
            for (args, status) in cases {
                let result = wwi(args, db: db)
                #expect(result.status == status, "\(args)")
                #expect(result.object?["ok"] as? Bool == false, "\(args): \(result.stdout)")
                #expect((result.object?["error"] as? String)?.isEmpty == false)
                #expect(!result.stderr.isEmpty)
            }
        }
    }

    /// 스크립트가 모든 명령에 `--json`을 똑같이 붙여도 성공 경로가 깨지면 안 된다.
    @Test func writeCommandsAcceptJSONAndReportOkWithId() throws {
        try withDatabase { db in
            let added = wwi(["add", "ok", "--json"], db: db)
            #expect(added.status == 0 && added.stderr.isEmpty)
            #expect(added.object?["ok"] as? Bool == true && added.object?["id"] as? Int == 1)

            let set = wwi(["set", "1", "--note", "x", "--json"], db: db)
            #expect(set.status == 0 && set.object?["ok"] as? Bool == true && set.object?["id"] as? Int == 1)
            let done = wwi(["done", "1", "--json"], db: db)
            #expect(done.status == 0 && done.object?["ok"] as? Bool == true && done.object?["id"] as? Int == 1)

            let shown = wwi(["show", "1", "--json"], db: db).object
            #expect(shown?["note"] as? String == "x" && shown?["status"] as? String == "done")

            for args in [["set", "999", "--note", "x", "--json"], ["done", "999", "--json"]] {
                let failed = wwi(args, db: db)
                #expect(failed.status == 1 && failed.object?["ok"] as? Bool == false, "\(args)")
            }
        }
    }

    @Test func helpUnderJSONIsNotAnError() throws {
        try withDatabase { db in
            let result = wwi(["ls", "--json", "--help"], db: db)
            #expect(result.status == 0)
            #expect(result.object == nil)
        }
    }

    /// 중첩 서브커맨드의 도움말은 그 서브커맨드 것이어야 하고(루트 도움말이 아니다), `--json`을 줘도 봉투 없이 그대로 나온다.
    @Test func nestedSubcommandHelpIsTheSubcommandsOwn() throws {
        try withDatabase { db in
            for arguments in [["hooks", "install", "--help"], ["help", "hooks", "install"], ["hooks", "install", "--help", "--json"]] {
                let result = wwi(arguments, db: db)
                #expect(result.status == 0, "\(arguments)")
                #expect(result.stdout.contains("USAGE: wwi hooks install"), "\(arguments)")
                #expect(result.stdout.contains("--wwi-path"), "\(arguments)")
                #expect(result.object == nil, "\(arguments)")
            }
        }
    }

    @Test func goDryRunReportHasExplicitNullsAndSameLocationAsRealTarget() throws {
        try withDatabase { db in
            let store = try Store(path: db)
            let ticket = try store.createTicket(title: "t")
            try store.addLocation(ticketId: ticket.id, locator: .claudeCode(.init(sessionId: "s", cwd: "/w")), source: .hook)
            let terminal = try store.addLocation(
                ticketId: ticket.id, locator: .orcaTerminal(.init(terminalHandle: "term_1")), source: .manual)
            let report = wwi(["go", "1", "--dry-run", "--json", "--location", "1"], db: db).object
            #expect(report?["ok"] as? Bool == true && report?["dryRun"] as? Bool == true)
            #expect(report?["message"] is NSNull)
            #expect((report?["commands"] as? [[String: Any]])?.first?["stdin"] is NSNull)
            #expect(report?["locationId"] as? Int == Int(terminal.id))
            #expect(report?["kind"] as? String == "orca_terminal")
        }
    }
}

@Suite struct CLISetSemanticsTests {
    @Test func setClearsFieldsWithEmptyStringAndNone() throws {
        try withDatabase { db in
            _ = wwi(["add", "t", "--project", "p", "--next", "n"], db: db)
            #expect(wwi(["set", "1", "--priority", "2", "--note", "hello"], db: db).status == 0)
            var shown = wwi(["show", "1", "--json"], db: db).object
            #expect(shown?["priority"] as? Int == 2 && shown?["note"] as? String == "hello")

            #expect(wwi(["set", "1", "--next", "", "--project", "", "--note", " ", "--priority", "none"], db: db).status == 0)
            shown = wwi(["show", "1", "--json"], db: db).object
            for key in ["priority", "project", "nextAction", "note"] { #expect(shown?[key] is NSNull, "\(key)") }
            #expect(shown?["title"] as? String == "t")
        }
    }

    @Test func titlePinSemantics() throws {
        try withDatabase { db in
            let store = try Store(path: db)
            let auto = try store.createTicket(title: "auto title")
            #expect(try store.getTicket(id: auto.id).pinnedTitle == false)
            #expect(wwi(["set", "1", "--title", "Mine"], db: db).status == 0)
            var shown = wwi(["show", "1", "--json"], db: db).object
            #expect(shown?["title"] as? String == "Mine" && shown?["pinnedTitle"] as? Bool == true)
            #expect(try store.autoUpdateTitle(id: 1, title: "auto again") == false)

            #expect(wwi(["set", "1", "--unpin-title"], db: db).status == 0)
            shown = wwi(["show", "1", "--json"], db: db).object
            #expect(shown?["pinnedTitle"] as? Bool == false && shown?["title"] as? String == "Mine")
            #expect(try store.autoUpdateTitle(id: 1, title: "auto again"))
        }
    }

    @Test func onlyStatusChangesBumpLastActivity() throws {
        try withDatabase { db in
            let old = Date(timeIntervalSince1970: 1_000_000)
            let store = try Store(path: db, now: { old })
            _ = try store.createTicket(title: "t")
            _ = try store.createTicket(title: "u")

            func activity(_ id: Int) -> Date? {
                let shown = wwi(["show", "\(id)", "--json"], db: db).object
                return (shown?["lastActivityAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            }
            #expect(wwi(["set", "1", "--note", "x", "--project", "p", "--priority", "1", "--title", "T"], db: db).status == 0)
            #expect(activity(1) == old)
            #expect(wwi(["go", "1", "--dry-run"], db: db).status == 1)   // 위치가 없어서 실패해도 활동은 그대로
            #expect(activity(1) == old)

            #expect(wwi(["set", "1", "--status", "waiting"], db: db).status == 0)
            #expect((activity(1) ?? old) > old)
            #expect(wwi(["done", "2"], db: db).status == 0)
            #expect((activity(2) ?? old) > old)
            #expect(wwi(["show", "2", "--json"], db: db).object?["status"] as? String == "done")
        }
    }
}

@Suite struct CLIListTests {
    @Test func lsDefaultsHideDoneAndOrderByStatusGroup() throws {
        try withDatabase { db in
            let store = try Store(path: db)
            for (title, status) in [("d", TicketStatus.done), ("b", .blocked), ("i", .inbox), ("a", .active), ("w", .waiting)] {
                _ = try store.createTicket(title: title, status: status)
            }
            let lines = wwi(["ls"], db: db).stdout.split(separator: "\n").map(String.init)
            #expect(lines.count == 4)
            let statuses = lines.map { $0.split(separator: " ", omittingEmptySubsequences: true)[1] }
            #expect(statuses == ["waiting", "active", "inbox", "blocked"])
            #expect(wwi(["ls", "--all"], db: db).stdout.split(separator: "\n").count == 5)
            #expect(wwi(["ls", "--status", "done", "--status", "active"], db: db).stdout.split(separator: "\n").count == 2)
        }
    }

    /// S5: `ls`가 보여 주는 위치와 `go`가 여는 위치가 같다.
    @Test func lsDisplaysTheSameLocationThatGoTargets() throws {
        try withDatabase { db in
            let clock = TestClock()
            let store = try Store(path: db, now: { clock.current })
            let ticket = try store.createTicket(title: "mixed")
            try store.addLocation(ticketId: ticket.id, locator: .url(.init(url: "https://old.example")), source: .manual)
            clock.advance(600)
            let codex = try store.addLocation(
                ticketId: ticket.id, locator: .codexThread(.init(threadId: "019a-thread")), source: .hook)

            let line = wwi(["ls"], db: db).stdout
            #expect(line.contains("codex") && !line.contains("url  "))
            let plan = wwi(["go", "1", "--dry-run", "--json"], db: db).object
            #expect(plan?["locationId"] as? Int == Int(codex.id))
            #expect(plan?["kind"] as? String == "codex_thread")
        }
    }

    @Test func lsSkipsCorruptRowsWithAWarning() throws {
        try withDatabase { db in
            let store = try Store(path: db)
            _ = try store.createTicket(title: "good")
            let bad = try store.createTicket(title: "bad")
            rawSQL(db, "UPDATE tickets SET status = 'from-the-future' WHERE id = \(bad.id)") { _ in }
            let result = wwi(["ls", "--all"], db: db)
            #expect(result.status == 0)
            #expect(result.stdout.contains("good") && !result.stdout.contains("bad"))
            #expect(result.stderr.contains("warning") && result.stderr.contains("ticket \(bad.id)"))
        }
    }
}

@Suite struct CLIConcurrencyTests {
    /// B1의 CLI 버전: 새 DB에 `wwi ls` 8개를 동시에 띄워도 전부 성공해야 한다.
    @Test func parallelFirstRunsOnFreshDatabaseAllSucceed() throws {
        let failures = FailureCounter()
        for round in 0..<10 {
            try withDatabase { db in
                DispatchQueue.concurrentPerform(iterations: 8) { worker in
                    let result = wwi(["ls"], db: db)
                    if result.status != 0 { failures.add("round \(round) #\(worker): \(result.stderr)") }
                }
            }
        }
        #expect(failures.all.isEmpty, "\(failures.all.prefix(3))")
    }
}

final class FailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
