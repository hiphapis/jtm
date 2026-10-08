import ArgumentParser
import Foundation
import WWICore

struct PruneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune", abstract: "쌓인 자동 수집 티켓을 정리한다",
        subcommands: [PruneWorkersCommand.self])
}

struct PruneWorkersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workers",
        abstract: "Orca 오케스트레이션 워커가 만든 티켓을 지운다 (손대지 않은 것만; 읽기 전용 Orca 명령으로 워커 handle을 먼저 새로 읽는다)")

    @Flag(name: .customLong("dry-run"), help: "지우지 않고 무엇을 지울지만 출력한다") var dryRun = false
    @Flag(help: "JSON으로 출력") var json = false

    private struct Report: Encodable {
        var ok = true
        var dryRun: Bool
        var removed: [PruneReport.Entry]
        var keptTouched: [PruneReport.Entry]
        var workerRefresh: WorkerRefreshReport?
    }

    func run() throws {
        // handle 조회는 5분 제한 없이 항상 새로 한다. Orca가 없거나 실패해도 제목과 저장된 handle로 정리한다(실패는 출력에 남는다).
        let now = Date()
        let workers: WorkerFetch
        if let orca = OrcaCLI.locate() {
            workers = OrcaWorkers.fetch(runner: ProcessRunner(), orca: orca, now: now)
        } else {
            workers = WorkerFetch(error: "\(SyncError.orcaNotFound)")
        }
        // --dry-run은 DB를 만들지 않는다(`wwi sync orca --dry-run`과 같다).
        let store = dryRun && !FileManager.default.fileExists(atPath: databasePath())
            ? try Store(path: ":memory:") : try openStore()
        let report = try WorkerPruner(store: store).prune(workers: workers, dryRun: dryRun, now: now)

        if json {
            try printJSON(Report(
                dryRun: dryRun, removed: report.removed, keptTouched: report.keptTouched, workerRefresh: report.workerRefresh))
            return
        }
        if let failure = report.workerRefresh?.error {
            FileHandle.standardError.write(Data("warning: worker refresh failed (\(failure)); using stored handles only\n".utf8))
        }
        let refresh = report.workerRefresh.map { "worker handles read from \($0.runs) runs: \($0.handles)" } ?? ""
        if !refresh.isEmpty { print(refresh) }
        let verb = dryRun ? "would remove" : "removed"
        print("\(verb) \(report.removed.count) worker ticket(s)\(dryRun ? " (dry run)" : "")")
        for entry in report.removed { print("  \(line(entry))") }
        if !report.keptTouched.isEmpty {
            print("kept \(report.keptTouched.count) touched worker ticket(s)")
            for entry in report.keptTouched { print("  \(line(entry))") }
        }
    }

    private func line(_ entry: PruneReport.Entry) -> String {
        "\(pad("#\(entry.id)", 5))\(pad(entry.status.rawValue, 8)) \(pad(entry.reason, 19)) \(entry.title)"
    }
}
