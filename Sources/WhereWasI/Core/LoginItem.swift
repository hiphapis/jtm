import Foundation

/// 실행 인자 `--login-item on|off|status`: `open -a "Where Was I" --args --login-item on`처럼 앱을 띄우면서 로그인 시 자동 실행을 켜고 끈다.
/// 실행 결과는 로그(`~/Library/Logs/jtm/app.log`)에 남기고, 앱은 평소처럼 계속 돈다.
public enum LoginItemAction: String, Equatable, Sendable {
    case on, off, status
}

public enum LoginItemArgument: Equatable, Sendable {
    /// 인자가 없다.
    case none
    case action(LoginItemAction)
    /// 값이 없거나 모르는 값(`--login-item`, `--login-item maybe`). 로그에 남기고 아무것도 바꾸지 않는다.
    case invalid(String?)

    /// 프로세스 인자(`CommandLine.arguments`, 첫 칸은 실행 파일)를 읽는다. 모르는 인자는 무시한다(macOS가 `-NSDocument…` 같은 것을 붙인다).
    /// `--login-item on`과 `--login-item=on` 둘 다 받는다. 여러 번 주면 마지막 것을 쓴다.
    public static func parse(_ arguments: [String]) -> LoginItemArgument {
        var result = LoginItemArgument.none
        var index = arguments.startIndex
        // 실행 파일 경로는 건너뛴다.
        if index < arguments.endIndex { index = arguments.index(after: index) }
        while index < arguments.endIndex {
            let argument = arguments[index]
            index = arguments.index(after: index)
            if argument == "--login-item" {
                if index < arguments.endIndex, !arguments[index].hasPrefix("-") {
                    result = interpret(arguments[index])
                    index = arguments.index(after: index)
                } else {
                    result = .invalid(nil)
                }
            } else if argument.hasPrefix("--login-item=") {
                result = interpret(String(argument.dropFirst("--login-item=".count)))
            }
        }
        return result
    }

    private static func interpret(_ value: String) -> LoginItemArgument {
        LoginItemAction(rawValue: value).map(LoginItemArgument.action) ?? .invalid(value)
    }
}

/// `SMAppService.Status`와 같은 뜻의 값(테스트에서 `ServiceManagement` 없이 쓰려고 따로 둔다).
public enum LoginItemStatus: String, Equatable, Sendable {
    case enabled
    case notRegistered = "not_registered"
    /// 등록은 됐지만 사용자가 시스템 설정 > 로그인 항목에서 허용해야 한다(ad-hoc 서명 앱).
    case requiresApproval = "requires_approval"
    case notFound = "not_found"
    case unknown
}

public protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// 인자대로 로그인 항목을 바꾸고 결과(와 상태)를 한 줄로 `log`에 남긴다. 오류도 줄로 남길 뿐 던지지 않는다.
public enum LoginItemRunner {
    @discardableResult
    public static func run(_ argument: LoginItemArgument, service: LoginItemService, log: (String) -> Void) -> String? {
        let line: String
        switch argument {
        case .none:
            return nil
        case .invalid(let value):
            line = "login-item: invalid argument \(value.map { "'\($0)'" } ?? "(missing value)"); expected on|off|status"
        case .action(.status):
            line = "login-item status: \(describe(service.status))"
        case .action(.on):
            let before = service.status
            // 이미 등록돼 있으면(허용 대기 포함) 다시 등록하지 않는다.
            if before == .enabled || before == .requiresApproval {
                line = "login-item on: already registered; status=\(describe(before))"
            } else {
                line = attempt("on", before: before, service: service) { try service.register() }
            }
        case .action(.off):
            let before = service.status
            if before == .notRegistered || before == .notFound {
                line = "login-item off: already unregistered; status=\(describe(before))"
            } else {
                line = attempt("off", before: before, service: service) { try service.unregister() }
            }
        }
        log(line)
        return line
    }

    private static func attempt(_ name: String, before: LoginItemStatus, service: LoginItemService, _ change: () throws -> Void) -> String {
        do {
            try change()
            return "login-item \(name): ok; status=\(describe(service.status))"
        } catch {
            let message = "\(error.localizedDescription)".split(whereSeparator: \.isNewline).joined(separator: " ")
            return "login-item \(name): failed (\(message)); status=\(describe(service.status))"
        }
    }

    private static func describe(_ status: LoginItemStatus) -> String {
        status == .requiresApproval ? "\(status.rawValue) (approve Where Was I in System Settings > General > Login Items)" : status.rawValue
    }
}

/// `~/Library/Logs/jtm/app.log`에 한 줄씩 덧붙인다. 폴더는 0700, 파일은 0600이다(`wwi ingest`의 로그와 같은 규칙).
/// 읽는 쪽이 없는 FIFO 같은 경로에서 막히지 않도록 `O_NONBLOCK`으로 연다. 로그를 못 써도 조용히 넘어간다.
public struct AppLog: Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    public static func standard(home: String = NSHomeDirectory()) -> AppLog {
        AppLog(path: home + "/Library/Logs/jtm/app.log")
    }

    public func append(_ message: String, now: Date = Date()) {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let singleLine = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        let line = "\(ISO8601DateFormatter().string(from: now)) \(singleLine)\n"
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var info = stat()
        if fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_mode & 0o077 != 0 {
            fchmod(descriptor, 0o600)
        }
        _ = line.withCString { write(descriptor, $0, strlen($0)) }
    }
}
