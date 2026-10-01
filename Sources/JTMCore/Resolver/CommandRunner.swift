import Foundation

public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }

    /// 시간 초과로 강제 종료된 결과(`timeout(1)`의 관례대로 124).
    public static let timedOutExitCode: Int32 = 124
    public var timedOut: Bool { exitCode == Self.timedOutExitCode }
}

/// 리졸버의 모든 부수효과(open, orca, pbcopy)는 이 프로토콜을 거친다.
/// `timeout` 안에 끝나지 않으면 프로세스를 종료하고 exit 124 + "timed out" stderr를 돌려줘야 한다.
public protocol CommandRunner {
    func run(_ argv: [String], stdin: String?, timeout: TimeInterval) -> CommandResult
}

public struct ProcessRunner: CommandRunner {
    public init() {}

    /// `/usr/bin/env`로 실행해 PATH에서 명령을 찾는다. 실행 자체가 실패하면 exit 127.
    public func run(_ argv: [String], stdin: String?, timeout: TimeInterval) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        let stdoutPipe = Pipe(), stderrPipe = Pipe(), stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdin == nil ? FileHandle.nullDevice : stdinPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do { try process.run() } catch {
            return CommandResult(exitCode: 127, stderr: "\(error)")
        }
        // 파이프가 가득 차 자식이 멈추지 않도록 stdout/stderr 모두 별도 스레드에서 비운다.
        let stdoutReader = PipeReader(stdoutPipe.fileHandleForReading)
        let stderrReader = PipeReader(stderrPipe.fileHandleForReading)
        if let stdin {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        let stdout = String(decoding: stdoutReader.snapshot(), as: UTF8.self)
        var stderr = String(decoding: stderrReader.snapshot(), as: UTF8.self)
        if timedOut {
            stderr += (stderr.isEmpty || stderr.hasSuffix("\n") ? "" : "\n")
                + "timed out after \(timeout.formatted(.number.precision(.fractionLength(0...1))))s"
            return CommandResult(exitCode: CommandResult.timedOutExitCode, stdout: stdout, stderr: stderr)
        }
        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

/// 파이프를 EOF까지 읽어 모은다. 자식이 파이프를 물려받은 손자 프로세스를 남겨도 `snapshot()`은 잠깐만 기다린다.
private final class PipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let finished = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        // 전용 스레드: GCD 전역 큐는 다른 작업이 스레드를 다 쓰고 있으면 리더가 시작조차 못 해서 `snapshot()`이 빈 출력을 돌려줄 수 있다.
        Thread.detachNewThread {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                self.lock.lock()
                self.data.append(chunk)
                self.lock.unlock()
            }
            self.finished.signal()
        }
    }

    func snapshot() -> Data {
        _ = finished.wait(timeout: .now() + 1)
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
