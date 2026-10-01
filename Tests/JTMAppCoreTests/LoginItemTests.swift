import Foundation
import Testing
@testable import JTMAppCore

// `--login-item on|off|status`: 인자 해석과 실행기. 실제 `SMAppService`는 쓰지 않는다(등록하면 로그인 항목이 바뀐다).

private final class FakeService: LoginItemService {
    var status: LoginItemStatus
    var afterRegister: LoginItemStatus
    var failure: Error?
    private(set) var calls: [String] = []

    init(_ status: LoginItemStatus, afterRegister: LoginItemStatus = .enabled, failure: Error? = nil) {
        self.status = status
        self.afterRegister = afterRegister
        self.failure = failure
    }

    func register() throws {
        calls.append("register")
        if let failure { throw failure }
        status = afterRegister
    }

    func unregister() throws {
        calls.append("unregister")
        if let failure { throw failure }
        status = .notRegistered
    }
}

private struct Boom: LocalizedError { var errorDescription: String? { "boom\nsecond line" } }

@Suite struct LoginItemArgumentTests {
    private func parse(_ arguments: String...) -> LoginItemArgument { LoginItemArgument.parse(["/Applications/JTM.app/Contents/MacOS/JTMApp"] + arguments) }

    @Test func recognizesOnOffAndStatus() {
        #expect(parse("--login-item", "on") == .action(.on))
        #expect(parse("--login-item", "off") == .action(.off))
        #expect(parse("--login-item", "status") == .action(.status))
    }

    @Test func acceptsTheEqualsForm() {
        #expect(parse("--login-item=on") == .action(.on))
        #expect(parse("--login-item=status") == .action(.status))
    }

    @Test func noArgumentIsNone() {
        #expect(LoginItemArgument.parse([]) == LoginItemArgument.none)
        #expect(parse() == LoginItemArgument.none)
        #expect(parse("-NSDocumentRevisionsDebugMode", "YES", "-ApplePersistenceIgnoreState", "YES") == LoginItemArgument.none)
    }

    @Test func theExecutablePathIsNotAnArgument() {
        #expect(LoginItemArgument.parse(["--login-item", "on"]) == LoginItemArgument.none)
    }

    @Test func unknownArgumentsAroundItAreIgnored() {
        #expect(parse("-NSDocumentRevisionsDebugMode", "YES", "--login-item", "off", "--other") == .action(.off))
    }

    @Test func aMissingOrUnknownValueIsInvalid() {
        #expect(parse("--login-item") == .invalid(nil))
        #expect(parse("--login-item", "--other") == .invalid(nil))
        #expect(parse("--login-item", "maybe") == .invalid("maybe"))
        #expect(parse("--login-item=") == .invalid(""))
        #expect(parse("--login-item", "ON") == .invalid("ON"))
    }

    @Test func theLastOccurrenceWins() {
        #expect(parse("--login-item", "on", "--login-item", "off") == .action(.off))
    }
}

@Suite struct LoginItemRunnerTests {
    private func run(_ argument: LoginItemArgument, _ service: FakeService) -> (line: String?, logged: [String]) {
        var logged: [String] = []
        let line = LoginItemRunner.run(argument, service: service, log: { logged.append($0) })
        return (line, logged)
    }

    @Test func onRegistersAndLogsTheResultingStatus() {
        let service = FakeService(.notRegistered)
        let result = run(.action(.on), service)
        #expect(service.calls == ["register"])
        #expect(result.logged == ["login-item on: ok; status=enabled"])
    }

    @Test func onLogsRequiresApprovalWithTheHint() {
        let service = FakeService(.notRegistered, afterRegister: .requiresApproval)
        let line = run(.action(.on), service).line ?? ""
        #expect(line.hasPrefix("login-item on: ok; status=requires_approval") && line.contains("System Settings"))
    }

    @Test func onWhenAlreadyRegisteredDoesNotRegisterAgain() {
        for before in [LoginItemStatus.enabled, .requiresApproval] {
            let service = FakeService(before)
            let line = run(.action(.on), service).line ?? ""
            #expect(service.calls.isEmpty && line.hasPrefix("login-item on: already registered; status=\(before.rawValue)"))
        }
    }

    @Test func offUnregistersAndIsANoOpWhenAlreadyOff() {
        let on = FakeService(.enabled)
        #expect(run(.action(.off), on).logged == ["login-item off: ok; status=not_registered"] && on.calls == ["unregister"])
        let off = FakeService(.notRegistered)
        #expect(run(.action(.off), off).logged == ["login-item off: already unregistered; status=not_registered"] && off.calls.isEmpty)
    }

    @Test func statusOnlyReadsAndLogs() {
        for status in [LoginItemStatus.enabled, .notRegistered, .notFound, .unknown] {
            let service = FakeService(status)
            #expect(run(.action(.status), service).logged == ["login-item status: \(status.rawValue)"] && service.calls.isEmpty)
        }
        let approval = FakeService(.requiresApproval)
        #expect((run(.action(.status), approval).line ?? "").hasPrefix("login-item status: requires_approval"))
    }

    @Test func aFailureIsLoggedOnOneLineWithTheStatusAndNeverThrown() {
        let service = FakeService(.notRegistered, failure: Boom())
        let result = run(.action(.on), service)
        #expect(result.logged == ["login-item on: failed (boom second line); status=not_registered"])
    }

    @Test func invalidArgumentsAreLoggedAndChangeNothing() {
        let service = FakeService(.notRegistered)
        #expect(run(.invalid("maybe"), service).logged == ["login-item: invalid argument 'maybe'; expected on|off|status"])
        #expect(run(.invalid(nil), service).logged == ["login-item: invalid argument (missing value); expected on|off|status"])
        #expect(service.calls.isEmpty)
    }

    @Test func noArgumentDoesNothing() {
        let service = FakeService(.notRegistered)
        let result = run(.none, service)
        #expect(result.line == nil && result.logged.isEmpty && service.calls.isEmpty)
    }
}

@Suite struct AppLogTests {
    private func permissions(_ path: String) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }

    @Test func appendsTimestampedLinesWithOwnerOnlyPermissions() throws {
        let root = NSTemporaryDirectory() + "jtm-applog-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let log = AppLog(path: root + "/Logs/jtm/app.log")
        log.append("first", now: Date(timeIntervalSince1970: 0))
        log.append("second\nline")
        let text = try String(contentsOfFile: log.path, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 2 && lines[0] == "1970-01-01T00:00:00Z first" && lines[1].hasSuffix(" second line"))
        #expect(try permissions(log.path) == 0o600 && permissions(root + "/Logs/jtm") == 0o700)
    }

    @Test func tightensAnExistingLooseFile() throws {
        let root = NSTemporaryDirectory() + "jtm-applog-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let path = root + "/app.log"
        FileManager.default.createFile(atPath: path, contents: Data("old\n".utf8), attributes: [.posixPermissions: 0o644])
        AppLog(path: path).append("new")
        #expect(try permissions(path) == 0o600)
        #expect(try String(contentsOfFile: path, encoding: .utf8).hasPrefix("old\n"))
    }

    @Test func standardPathIsUnderTheHomeLogsFolder() {
        #expect(AppLog.standard(home: "/Users/me/h").path == "/Users/me/h/Library/Logs/jtm/app.log")
    }

    @Test func anUnwritablePathIsIgnored() {
        AppLog(path: "/dev/null/app.log").append("nothing happens")  // 던지지 않는다
    }
}
