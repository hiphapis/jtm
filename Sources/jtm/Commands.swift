import ArgumentParser
import Foundation
import JTMCore

private func rejectBlank(_ value: String?, _ name: String) throws {
    if let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw ValidationError("\(name) must not be empty.")
    }
}

struct AddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "티켓을 만들고 새 id를 출력한다")

    @Argument(help: "티켓 제목 (직접 입력한 제목은 고정된다)") var title: String
    @Option(help: "붙일 URL (chatgpt/claude 채팅 URL은 자동 분류)") var url: String?
    @Option(name: .customLong("orca-terminal"), help: "붙일 Orca 터미널 handle") var orcaTerminal: String?
    @Option(help: "프로젝트") var project: String?
    @Option(name: .customLong("next"), help: "다음에 할 일") var nextAction: String?
    @Option(help: "초기 상태 (inbox|active|waiting|blocked|done)") var status: TicketStatus = .inbox
    @Flag(help: "JSON으로 출력 ({\"ok\":true,\"id\":N})") var json = false

    func validate() throws {
        try rejectBlank(title, "title")
        try rejectBlank(url, "--url")
        try rejectBlank(orcaTerminal, "--orca-terminal")
    }

    func run() throws {
        let store = try openStore()
        // 티켓과 위치가 한 트랜잭션이라, 중간에 실패해도 위치 없는 티켓이 남지 않는다.
        let id = try store.transaction {
            let ticket = try store.createTicket(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines), status: status,
                project: project, nextAction: nextAction, pinnedTitle: true, kept: true)
            if let orcaTerminal {
                try store.addLocation(
                    ticketId: ticket.id, locator: .orcaTerminal(.init(terminalHandle: orcaTerminal)),
                    source: .manual)
            }
            if let url {
                try store.addLocation(ticketId: ticket.id, locator: URLClassifier.classify(url), source: .manual)
            }
            return ticket.id
        }
        if json { try printJSON(WriteEnvelope(id: id)) } else { print(id) }
    }
}

struct LsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "티켓 목록 (기본: done과 보관함 제외)")

    @Option(help: "이 상태만 (여러 번 지정 가능)") var status: [TicketStatus] = []
    @Flag(help: "done과 보관함까지 모두 보기") var all = false
    @Flag(help: "보관함에 있는 티켓만 보기") var archived = false
    @Flag(help: "JSON으로 출력") var json = false

    func validate() throws {
        if all, archived { throw ValidationError("--all and --archived cannot be combined (--all already includes the archive).") }
    }

    func run() throws {
        let store = try openStore()
        // 기본은 done과 보관함을 숨긴다. --status는 그 상태만(보관함은 여전히 숨김), --archived는 보관함만, --all은 전부.
        let statuses: Set<TicketStatus>? =
            !status.isEmpty ? Set(status) : (all || archived) ? nil : Set(TicketStatus.allCases).subtracting([.done])
        let scope: Store.ArchiveScope = all ? .all : archived ? .onlyArchived : .excludingArchived
        let tickets = try store.listTickets(statuses: statuses, archive: scope)
        let details = try tickets.map { TicketDetail(ticket: $0, locations: try store.locations(ticketId: $0.id)) }

        if json {
            try printJSON(details)
            return
        }
        let now = Date()
        for detail in details {
            let ticket = detail.ticket
            // `jtm go`가 여는 위치와 같은 정의(Resolver.choose)를 쓴다.
            let primary = Resolver.choose(from: detail.locations)
            var parts = [
                pad("#\(ticket.id)", 4),
                pad(statusLabel(ticket), 19),
                primary.map { pad("\($0.kind.icon) \($0.kind.label)", 14) } ?? pad("—", 14),
                ticket.title,
            ]
            if let project = ticket.project { parts.append("[\(project)]") }
            parts.append(RelativeTime.string(from: ticket.lastActivityAt, now: now))
            if ticket.kept { parts.append("★") }
            if let next = ticket.nextAction { parts.append("→ \(next)") }
            print(parts.joined(separator: "  "))
        }
    }
}

struct ShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "티켓과 모든 위치를 보여준다")

    @Argument(help: "티켓 id") var id: Int64
    @Flag(help: "JSON으로 출력") var json = false

    func run() throws {
        let store = try openStore()
        let ticket = try store.getTicket(id: id)
        let locations = try store.locations(ticketId: id)

        if json {
            try printJSON(TicketDetail(ticket: ticket, locations: locations))
            return
        }
        let now = Date()
        func ago(_ date: Date) -> String { RelativeTime.string(from: date, now: now) }

        print("#\(ticket.id)  \(ticket.title)\(ticket.pinnedTitle ? "  (pinned)" : "")")
        print("status:   \(statusLabel(ticket))")
        if let priority = ticket.priority { print("priority: \(priority)") }
        if let project = ticket.project { print("project:  \(project)") }
        if let next = ticket.nextAction { print("next:     \(next)") }
        if let note = ticket.note { print("note:     \(note)") }
        if let ended = ticket.endedAt { print("ended:    \(ago(ended))") }
        if ticket.kept { print("kept:     ★ (자동 완료·보관 제외)") }
        if let archived = ticket.archivedAt { print("archived: \(ago(archived))") }
        print("created \(ago(ticket.createdAt)) · updated \(ago(ticket.updatedAt)) · activity \(ago(ticket.lastActivityAt))")
        print("locations:")
        if locations.isEmpty { print("  (none)") }
        for location in locations {
            let locator = String(decoding: try location.locator.jsonData(), as: UTF8.self)
            let key = location.externalKey.map { ", key=\($0)" } ?? ""
            print("  \(location.kind.icon) \(location.kind.rawValue)  \(locator)  [\(location.source.rawValue), seen \(ago(location.lastSeenAt))\(key)]")
        }
    }
}

struct SetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "티켓 필드를 바꾼다 (--next/--project/--note에 빈 문자열, --priority에 none을 주면 지운다)")

    @Argument(help: "티켓 id") var id: Int64
    @Option(help: "제목 (지정하면 제목을 고정해 자동 갱신을 멈춘다)") var title: String?
    @Flag(name: .customLong("unpin-title"), help: "제목 고정을 풀어 자동 갱신을 다시 허용한다") var unpinTitle = false
    @Option(help: "상태 (inbox|active|waiting|blocked|done)") var status: TicketStatus?
    @Option(name: .customLong("next"), help: "다음에 할 일") var nextAction: String?
    @Option(help: "우선순위 (정수, 지우려면 none)") var priority: String?
    @Option(help: "프로젝트") var project: String?
    @Option(help: "메모") var note: String?
    @Flag(help: "JSON으로 출력 ({\"ok\":true,\"id\":N})") var json = false

    /// 정수면 그 값, `none`/빈 문자열이면 지움(`.some(nil)`), 그 밖에는 nil(잘못된 입력).
    private static func parsePriority(_ text: String) -> Int?? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "none" { return .some(nil) }
        return Int(trimmed).map { .some($0) }
    }

    func validate() throws {
        if title == nil, !unpinTitle, status == nil, nextAction == nil, priority == nil, project == nil, note == nil {
            throw ValidationError("바꿀 필드를 하나 이상 지정하세요 (--title, --unpin-title, --status, --next, --priority, --project, --note).")
        }
        try rejectBlank(title, "--title")
        if title != nil, unpinTitle { throw ValidationError("--title pins the title; it cannot be combined with --unpin-title.") }
        if let priority, Self.parsePriority(priority) == nil {
            throw ValidationError("--priority must be an integer or 'none'.")
        }
    }

    func run() throws {
        let store = try openStore()
        var patch = TicketPatch()
        if let title {
            patch.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            patch.pinnedTitle = true
        }
        if unpinTitle { patch.pinnedTitle = false }
        patch.status = status
        if let nextAction { patch.nextAction = .some(nilIfEmpty(nextAction)) }
        if let priority, let parsed = Self.parsePriority(priority) { patch.priority = parsed }
        if let project { patch.project = .some(nilIfEmpty(project)) }
        if let note { patch.note = .some(nilIfEmpty(note)) }
        // 지정한 컬럼만 쓰므로 다른 프로세스(훅)의 동시 변경을 되돌리지 않는다.
        // lastActivityAt은 status를 바꿀 때만 오른다. 제목/next/note를 고치거나 상태를 직접 바꾸면(done 제외) 유지(⭐)가 된다.
        try store.patchTicketAsUser(id: id, patch)
        if json { try printJSON(WriteEnvelope(id: id)) }
    }
}

struct DoneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "done", abstract: "티켓을 done으로 바꾼다")

    @Argument(help: "티켓 id") var id: Int64
    @Flag(help: "JSON으로 출력 ({\"ok\":true,\"id\":N})") var json = false

    func run() throws {
        try openStore().patchTicketAsUser(id: id, TicketPatch(status: .done))
        if json { try printJSON(WriteEnvelope(id: id)) }
    }
}
