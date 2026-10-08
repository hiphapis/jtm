import ArgumentParser
import Foundation
import WWICore

/// 훅이 부르는 명령: stdin의 훅 JSON 하나를 티켓에 반영한다.
/// 훅을 절대 막지 않는다: 항상 exit 0이고 stdout에는 아무것도 쓰지 않는다. 문제는 로그 파일에 한 줄로 남긴다.
/// 인자 오류도 종료 코드 64가 아니라 로그 + exit 0이다(`WWI.main`이 파싱 실패를 삼킨다).
/// 무슨 일이 있어도 `IngestWatchdog.limit`초 안에 끝난다.
struct IngestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ingest",
        abstract: "에이전트 훅 이벤트(stdin JSON)를 반영한다 — 항상 exit 0, stdout 없음")

    // 잘못된 값이나 모르는 옵션도 ArgumentParser의 종료 코드(64)가 아니라 로그 + exit 0으로 처리하려고 전부 받는다.
    @Argument(parsing: .allUnrecognized, help: "에이전트 (claude|codex)") var arguments: [String] = []

    func run() {
        IngestWatchdog.arm()
        let agent = arguments.first { !$0.hasPrefix("-") } ?? ""
        var event = "-"
        do {
            // 먼저 stdin을 (시간 제한 안에서) 읽는다: 안 읽고 끝내면 큰 페이로드를 쓰던 쪽이 EPIPE를 맞는다.
            let input = readStandardInput(limit: Ingest.inputLimit + 1)
            let environment = ProcessInfo.processInfo.environment
            guard !agent.isEmpty else { throw IngestError.missingAgent }
            // 헤드리스/중첩 세션은 아무것도 남기지 않는다(로그도, DB도).
            if Ingest.isNestedSession(agent: agent, environment: environment) { return }
            // 파싱과 걸러내기를 DB를 열기 전에 한다: 쓰레기 입력이나 무시할 이벤트(Notification 등)는 DB 파일도 잠금도 만들지 않는다.
            guard let parsed = try Ingest.parse(agent: agent, input: input, defaultCwd: FileManager.default.currentDirectoryPath) else {
                return
            }
            event = parsed.kind.rawValue
            let store = try Store(path: databasePath(), onWarning: { IngestLog.append(agent: agent, event: "-", message: "warning: \($0)") })
            try Reconciler(store: store, projectResolver: FileSystemProjectResolver())
                .apply(event: parsed, env: OrcaEnv(environment: environment), now: Date())
        } catch {
            IngestLog.append(agent: agent, event: event, message: "\(error)")
        }
    }
}

/// 어떤 이유로든(stdin이 안 닫힘, DB 잠금, 멈춘 파일 시스템) 정해진 시간이 지나면 exit 0으로 끝낸다.
/// 훅은 에이전트의 사용자 입력/권한 창을 붙잡고 있으므로 늦게 끝나는 것보다 이벤트를 하나 잃는 편이 낫다.
/// SQLite는 저널링으로 중간 종료에도 안전하다. `SIGALRM` 핸들러에서 `_exit`만 부른다(async-signal-safe).
enum IngestWatchdog {
    /// 워치독이 프로세스를 끝내는 시각(초). 설치된 훅 timeout(5초)보다 충분히 짧다.
    /// 진단/테스트용으로 `WWI_INGEST_WATCHDOG_MS`(50~10000)로 바꿀 수 있다.
    static let limit: Double = {
        if let raw = ProcessInfo.processInfo.environment["WWI_INGEST_WATCHDOG_MS"], let milliseconds = Double(raw),
           (50...10_000).contains(milliseconds) {
            return milliseconds / 1000
        }
        return 2.5
    }()
    /// stdin을 기다리는 최대 시간(초). 기본 워치독보다 짧아서 EOF가 안 와도 받은 데이터로 처리할 시간이 남는다.
    static let stdinLimit: Double = 1.5

    static func arm() {
        signal(SIGALRM) { _ in _exit(0) }
        var timer = itimerval(
            it_interval: timeval(tv_sec: 0, tv_usec: 0),
            it_value: timeval(tv_sec: Int(limit), tv_usec: Int32((limit - limit.rounded(.down)) * 1_000_000)))
        setitimer(ITIMER_REAL, &timer, nil)
    }
}

/// 파이프는 한 번에 덜 돌려줄 수 있어서 EOF나 `limit`바이트까지 이어 읽는다(한도를 넘겨 읽으면 호출자가 거절한다).
/// EOF가 오지 않아도 `IngestWatchdog.stdinLimit`초가 지나면 그때까지 받은 것만 돌려준다(`poll`로 기다린다).
private func readStandardInput(limit: Int) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    let start = DispatchTime.now().uptimeNanoseconds
    let budget = UInt64(IngestWatchdog.stdinLimit * 1_000_000_000)
    while data.count < limit {
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        guard elapsed < budget else { break }
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32((budget - elapsed) / 1_000_000) + 1)
        if ready < 0 {
            if errno == EINTR { continue }
            break
        }
        if ready == 0 || descriptor.revents & Int16(POLLNVAL) != 0 { break }  // 시간 초과 / 닫힌 stdin
        let count = read(STDIN_FILENO, &buffer, min(buffer.count, limit - data.count))
        if count > 0 {
            data.append(buffer, count: count)
        } else if count == 0 {
            break
        } else if errno != EINTR && errno != EAGAIN {
            break
        }
    }
    return data
}

/// `~/Library/Logs/jtm/ingest.log`(`WWI_LOG_PATH`로 바꿀 수 있다)에 한 줄씩 덧붙인다.
/// 훅 프로세스가 동시에 여러 개 떠도 `O_APPEND`로 한 번에 쓴 줄은 섞이지 않는다. 로그를 못 써도 조용히 넘어간다.
/// 읽는 쪽이 없는 FIFO 같은 경로에서 막히지 않도록 `O_NONBLOCK`으로 연다. 폴더는 0700, 파일은 0600이다.
private enum IngestLog {
    static func append(agent: String, event: String, message: String) {
        let path: String
        if let override = ProcessInfo.processInfo.environment["WWI_LOG_PATH"], !override.isEmpty {
            path = override
        } else {
            path = NSHomeDirectory() + "/Library/Logs/jtm/ingest.log"
        }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let singleLine = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(agent) \(event) \(singleLine)\n"
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var info = stat()
        if fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_mode & 0o077 != 0 {
            fchmod(descriptor, 0o600)  // 이전 버전이 0644로 만든 로그도 조인다
        }
        _ = line.withCString { write(descriptor, $0, strlen($0)) }
    }
}
