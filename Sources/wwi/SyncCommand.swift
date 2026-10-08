import ArgumentParser
import Foundation
import WWICore

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync", abstract: "외부 소스와 티켓을 맞춘다",
        subcommands: [SyncOrcaCommand.self])
}

struct SyncOrcaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orca",
        abstract: "Orca 폴러를 한 번 실행한다 (읽기 전용: worktree ps, terminal list)")

    @Flag(name: .customLong("dry-run"), help: "DB에 쓰지 않고 요약만 출력한다") var dryRun = false
    @Flag(help: "JSON으로 출력") var json = false

    private struct Report: Encodable {
        var ok = true
        var dryRun: Bool
        var summary: SyncSummary
    }

    func run() throws {
        // Orca를 먼저 읽는다: 실패하면 DB를 열지도 쓰지도 않는다.
        guard let orca = OrcaCLI.locate() else { throw SyncError.orcaNotFound }
        let snapshot = try OrcaSnapshot.fetch(runner: ProcessRunner(), orca: orca)

        // --dry-run은 DB를 만들지 않는다: 아직 DB가 없으면 빈 임시 메모리 DB에서 "처음 sync하면 무엇이 생기는지"만 계산한다.
        let store = dryRun && !FileManager.default.fileExists(atPath: databasePath())
            ? try Store(path: ":memory:") : try openStore()
        let sync = OrcaSync(store: store)
        let now = Date()
        // 워커 handle은 5분에 한 번만 조회한다(--dry-run도 같다). 조회가 실패해도 동기화는 이어진다: 실패는 요약에 남는다.
        let workers = OrcaWorkers.isRefreshDue(store: store, now: now)
            ? OrcaWorkers.fetch(runner: ProcessRunner(), orca: orca, now: now) : nil
        let summary = dryRun
            ? try sync.preview(snapshot, workers: workers, now: now) : try sync.apply(snapshot, workers: workers, now: now)
        if json {
            try printJSON(Report(dryRun: dryRun, summary: summary))
            return
        }
        var line = "created \(summary.created), updated \(summary.updated), stale \(summary.stale), gone \(summary.gone)"
        if summary.revived > 0 { line += ", revived \(summary.revived)" }
        if summary.skipped > 0 { line += ", skipped \(summary.skipped) (no terminal)" }
        if summary.workersIgnored > 0 { line += ", workers ignored \(summary.workersIgnored)" }
        if summary.ignoredTabs > 0 { line += ", ignored tabs \(summary.ignoredTabs)" }
        if summary.autoDone > 0 { line += ", auto-done \(summary.autoDone)" }
        if summary.archived > 0 { line += ", archived \(summary.archived)" }
        if let failure = summary.workerRefresh?.error { line += ", worker refresh failed: \(failure)" }
        if summary.truncated { line += " — Orca output was truncated, gone detection skipped" }
        print(dryRun ? "dry run: \(line)" : line)
    }
}
