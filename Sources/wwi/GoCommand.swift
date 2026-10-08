import ArgumentParser
import Foundation
import WWICore

struct GoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "go", abstract: "티켓의 위치로 이동한다 (Orca 터미널, 앱 딥링크, URL 등)")

    @Argument(help: "티켓 id") var id: Int64
    @Option(name: .customLong("location"), help: "이동할 위치 id (기본: orca_terminal 우선, 없으면 가장 최근 본 위치)")
    var locationId: Int64?
    @Flag(name: .customLong("dry-run"), help: "실행하지 않고 실행할 명령만 출력한다") var dryRun = false
    @Flag(help: "JSON으로 출력") var json = false

    /// 성공 보고서. 값이 없는 필드도 키를 생략하지 않고 `null`로 낸다. 실패는 전역 오류 봉투(`{"ok":false,"error":...}`)로 나간다.
    private struct Report: Encodable {
        var ticketId: Int64
        var locationId: Int64
        var kind: LocationKind
        var dryRun: Bool
        var message: String?
        var commands: [PlannedCommand]?
        let ok = true

        private enum CodingKeys: String, CodingKey { case ticketId, locationId, kind, dryRun, message, commands, ok }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(ticketId, forKey: .ticketId)
            try container.encode(locationId, forKey: .locationId)
            try container.encode(kind, forKey: .kind)
            try container.encode(dryRun, forKey: .dryRun)
            try container.encode(message, forKey: .message)
            try container.encode(commands, forKey: .commands)
            try container.encode(ok, forKey: .ok)
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    func run() throws {
        let store = try openStore()
        let resolver = Resolver(runner: ProcessRunner(), orcaCommand: OrcaCLI.locate())

        if dryRun {
            let plan = try resolver.planGo(ticketId: id, locationId: locationId, store: store)
            if json {
                try printJSON(Report(
                    ticketId: id, locationId: plan.location.id, kind: plan.location.kind,
                    dryRun: true, message: nil, commands: plan.commands))
                return
            }
            print("ticket #\(id) → location #\(plan.location.id) (\(plan.location.kind.rawValue)), dry run")
            for command in plan.commands {
                let stdin = command.stdin.map { " <<< \(shellQuote($0))" } ?? ""
                print("  \(command.argv.map(shellQuote).joined(separator: " "))\(stdin)")
                if let note = command.note { print("    # \(note)") }
            }
            return
        }

        let result = try resolver.go(ticketId: id, locationId: locationId, store: store)
        guard result.ok else { throw Failure(description: result.message) }
        if json {
            try printJSON(Report(
                ticketId: id, locationId: result.location.id, kind: result.location.kind,
                dryRun: false, message: result.message, commands: nil))
        } else {
            print(result.message)
        }
    }
}

private func shellQuote(_ text: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
    if !text.isEmpty, text.unicodeScalars.allSatisfy(safe.contains) { return text }
    return "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}
