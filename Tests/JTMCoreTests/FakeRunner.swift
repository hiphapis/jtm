import Foundation
@testable import JTMCore

/// 호출을 기록하고 미리 정한 결과를 돌려준다. 실제 프로세스는 실행하지 않는다.
final class FakeRunner: CommandRunner {
    struct Call: Equatable {
        var argv: [String]
        var stdin: String?
        var timeout: TimeInterval = 0
    }

    private(set) var calls: [Call] = []
    private var rules: [(prefix: [String], results: [CommandResult])] = []

    var argvs: [[String]] { calls.map(\.argv) }

    /// argv가 `prefix`로 시작하면 `results`를 차례로 돌려주고, 마지막 결과는 반복한다. 규칙이 없으면 성공(exit 0).
    func on(_ prefix: [String], _ results: CommandResult...) {
        rules.append((prefix, results))
    }

    func run(_ argv: [String], stdin: String?, timeout: TimeInterval) -> CommandResult {
        calls.append(Call(argv: argv, stdin: stdin, timeout: timeout))
        guard let index = rules.firstIndex(where: { argv.starts(with: $0.prefix) }) else {
            return CommandResult(exitCode: 0)
        }
        let results = rules[index].results
        if results.count > 1 { rules[index].results.removeFirst() }
        return results[0]
    }
}

// MARK: Orca CLI 응답 (실측 형태)

func switchOK(tabId: String, worktreeId: String, handle: String = "h") -> CommandResult {
    CommandResult(exitCode: 0, stdout: """
        {"id":"x","ok":true,"result":{"focus":{"handle":"\(handle)","tabId":"\(tabId)","worktreeId":"\(worktreeId)","navigated":true}}}
        """)
}

let switchStale = CommandResult(exitCode: 1, stdout: """
    {"id":"x","ok":false,"error":{"code":"terminal_handle_stale","message":"terminal_handle_stale"}}
    """)

func listOK(_ terminals: [(handle: String, ptyId: String, tabId: String)]) -> CommandResult {
    let items = terminals.map {
        #"{"handle":"\#($0.handle)","ptyId":"\#($0.ptyId)","tabId":"\#($0.tabId)","title":"t"}"#
    }
    return CommandResult(exitCode: 0, stdout: #"{"id":"x","ok":true,"result":{"terminals":[\#(items.joined(separator: ","))]}}"#)
}

func location(
    _ id: Int64, _ locator: Locator, ticketId: Int64 = 1, seen: TimeInterval = 1_800_000_000
) -> Location {
    Location(
        id: id, ticketId: ticketId, locator: locator, source: .manual, externalKey: nil,
        lastSeenAt: Date(timeIntervalSince1970: seen))
}

// MARK: 리졸버 테스트 공용 헬퍼

let orca = "/fake/orca"
let openOrca = ["open", "-a", "Orca"]
func switchArgv(_ handle: String) -> [String] { [orca, "terminal", "switch", "--terminal", handle, "--json"] }
let listArgv = [orca, "terminal", "list", "--json", "--limit", "500"]

func makeResolver(
    _ runner: FakeRunner, orcaCommand: String? = orca, sleep: @escaping (TimeInterval) -> Void = { _ in }
) -> Resolver {
    Resolver(runner: runner, orcaCommand: orcaCommand, sleep: sleep)
}

/// exit 1 + stderr만 있는 실패(Orca 런타임이 아직 준비되지 않았을 때처럼 JSON 봉투가 없는 경우).
let orcaNotReady = CommandResult(exitCode: 1, stderr: "Orca is not running")
