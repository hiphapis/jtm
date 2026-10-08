import ArgumentParser
import Foundation
import WWICore

struct RetitleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retitle",
        abstract: "\"참조한 ChatGPT 대화\" 머리말로 시작하는 제목을 바로잡는다 (Codex 세션 기록을 읽기 전용으로 쓴다; 고정한 제목은 건드리지 않는다)",
        discussion: "프롬프트는 DB에 없어서 ~/.codex/sessions(CODEX_HOME)의 rollout 파일에서 첫 프롬프트를 읽는다. 제목과 함께 g-p-… 프로젝트를 ChatGPT로 고치고 chatgpt_chat 위치를 붙인다. 다시 실행해도 같은 결과다.")

    @Flag(name: .customLong("dry-run"), help: "바꾸지 않고 무엇을 바꿀지만 출력한다") var dryRun = false
    @Flag(help: "JSON으로 출력") var json = false

    private struct Report: Encodable {
        var ok = true
        var dryRun: Bool
        var updated: [RetitleReport.Entry]
        var unresolved: [RetitleReport.Entry]
    }

    func run() throws {
        // --dry-run은 DB를 만들지 않는다(`wwi prune workers --dry-run`과 같다).
        let store = dryRun && !FileManager.default.fileExists(atPath: databasePath())
            ? try Store(path: ":memory:") : try openStore()
        let retitler = Retitler(store: store, codexHome: CodexRollout.defaultHome())
        let report = try retitler.retitle(dryRun: dryRun)

        if json {
            try printJSON(Report(dryRun: dryRun, updated: report.updated, unresolved: report.unresolved))
            return
        }
        print("\(dryRun ? "would update" : "updated") \(report.updated.count) ticket(s)\(dryRun ? " (dry run)" : "")")
        for entry in report.updated { print("  \(line(entry))") }
        if !report.unresolved.isEmpty {
            print("unresolved \(report.unresolved.count) ticket(s)")
            for entry in report.unresolved { print("  #\(entry.id) \(entry.title)  [\(entry.reason ?? "")]") }
        }
    }

    private func line(_ entry: RetitleReport.Entry) -> String {
        var parts = ["#\(entry.id)"]
        if let title = entry.newTitle { parts.append("title: \(quote(entry.title)) -> \(quote(title))") }
        if let project = entry.newProject { parts.append("project: \(entry.project ?? "-") -> \(project)") }
        if let chat = entry.attachedChat { parts.append("+chatgpt_chat \(chat)") }
        return parts.joined(separator: "  ")
    }

    private func quote(_ text: String) -> String {
        let singleLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return "\"\(singleLine.count > 60 ? String(singleLine.prefix(60)) + "…" : singleLine)\""
    }
}
