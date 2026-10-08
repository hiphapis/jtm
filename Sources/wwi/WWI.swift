import ArgumentParser
import Foundation

@main
struct WWI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wwi",
        abstract: "여러 에이전트/프로젝트를 가로지르는 개인 태스크 매니저",
        subcommands: [
            AddCommand.self,
            LsCommand.self,
            ShowCommand.self,
            SetCommand.self,
            DoneCommand.self,
            GoCommand.self,
            IngestCommand.self,
            HooksCommand.self,
            SyncCommand.self,
            PruneCommand.self,
            RetitleCommand.self,
            KeepCommand.self,
            UnkeepCommand.self,
            IgnoreCommand.self,
            RestoreCommand.self,
            IgnoredCommand.self,
            UnignoreCommand.self,
        ]
    )

    /// `--json`이 있으면 어떤 오류든(인자 오류 포함) stdout에 `{"ok":false,"error":"..."}`를 내고,
    /// 메시지는 평소처럼 stderr로, 종료 코드는 0이 아닌 값으로 끝낸다.
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            var command = try parseAsRoot(arguments)
            try command.run()
        } catch {
            // 훅이 부르는 `wwi ingest`는 인자 오류로도 절대 실패하지 않는다(종료 코드 0, 출력 없음). 도움말은 예외.
            if arguments.first == "ingest", exitCode(for: error) != .success { Foundation.exit(0) }
            // 도움말/버전(`--help`, `help <명령>`)은 `--json`이 있어도 오류가 아니다: 종료 코드 0으로 끝나는 것은 봉투를 내지 않는다.
            if arguments.contains("--json"), exitCode(for: error) != .success, !(error is ExitCode) {
                try? printJSON(ErrorEnvelope(error: message(for: error)))
            }
            exit(withError: error)
        }
    }
}
