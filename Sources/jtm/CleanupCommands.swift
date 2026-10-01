import ArgumentParser
import Foundation
import JTMCore

// 자동 정리 명령(docs/01-product/menubar-ui.md "자동 정리와 행 버튼"): 유지(⭐), 무시(🗑), 보관함 되살리기.

struct KeepCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keep", abstract: "티켓을 유지(⭐)한다 — 자동 완료·자동 보관을 받지 않는다 (보관 중이면 보관도 푼다)")

    @Argument(help: "티켓 id") var id: Int64
    @Flag(help: "JSON으로 출력 ({\"ok\":true,\"id\":N})") var json = false

    func run() throws {
        try openStore().setKept(id: id, true)
        if json { try printJSON(WriteEnvelope(id: id)) }
    }
}

struct UnkeepCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unkeep", abstract: "티켓의 유지(⭐)를 푼다 — 다시 자동 정리를 받는다")

    @Argument(help: "티켓 id") var id: Int64
    @Flag(help: "JSON으로 출력 ({\"ok\":true,\"id\":N})") var json = false

    func run() throws {
        try openStore().setKept(id: id, false)
        if json { try printJSON(WriteEnvelope(id: id)) }
    }
}

struct IgnoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ignore",
        abstract: "티켓을 지우고 그 세션(claude:/codex:)을 다시 수집하지 않는다 (같은 탭의 새 세션은 새 티켓이 된다)")

    @Argument(help: "티켓 id") var id: Int64
    @Flag(help: "JSON으로 출력 ({\"ok\":true,\"id\":N,\"ignoredSessions\":[…]})") var json = false

    private struct Envelope: Encodable {
        var ok = true
        var id: Int64
        var ignoredSessions: [String]
    }

    func run() throws {
        let result = try openStore().ignoreTicket(id: id)
        if json {
            try printJSON(Envelope(id: id, ignoredSessions: result.sessionKeys))
        }
    }
}

struct RestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore", abstract: "보관함에서 되살린다 (보관을 풀고 유지(⭐)로 만든다)")

    @Argument(help: "티켓 id") var id: Int64
    @Flag(help: "JSON으로 출력 ({\"ok\":true,\"id\":N})") var json = false

    func run() throws {
        try openStore().restoreTicket(id: id)
        if json { try printJSON(WriteEnvelope(id: id)) }
    }
}

struct IgnoredCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ignored",
        abstract: "수집하지 않기로 한 세션 목록(ignored_sessions): 키, 사유, 시각 — 잘못 무시한 세션은 `jtm unignore <키>`로 푼다")

    @Flag(help: "JSON으로 출력") var json = false

    private struct Entry: Encodable {
        var key: String
        var reason: String?
        var createdAt: Date?
    }

    func run() throws {
        let entries = try openStore().ignoredSessionRecords().map { Entry(key: $0.externalKey, reason: $0.reason, createdAt: $0.createdAt) }
        if json { try printJSON(entries); return }
        let formatter = ISO8601DateFormatter()
        for entry in entries {
            print("\(pad(entry.key, 48)) \(pad(entry.reason ?? "-", 22)) \(entry.createdAt.map(formatter.string(from:)) ?? "-")")
        }
    }
}

struct UnignoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unignore",
        abstract: "무시 목록에서 세션 키(예: codex:<id>, claude:<id>)를 뺀다 — 그 세션의 다음 훅 이벤트부터 다시 수집한다 (지워진 티켓은 돌아오지 않는다)")

    @Argument(help: "세션 키 (`jtm ignored`로 확인)") var key: String
    @Flag(help: "JSON으로 출력 ({\"ok\":true,\"key\":\"…\"})") var json = false

    private struct Envelope: Encodable {
        var ok = true
        var key: String
    }

    func run() throws {
        guard try openStore().unignoreSession(key) else { throw StoreError.sessionNotIgnored(key) }
        if json { try printJSON(Envelope(key: key)) }
    }
}
