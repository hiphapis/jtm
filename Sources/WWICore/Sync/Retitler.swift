import Foundation

/// `wwi retitle`가 한 일(또는 `--dry-run`이면 할 일).
public struct RetitleReport: Equatable, Sendable, Encodable {
    public struct Entry: Equatable, Sendable, Encodable {
        public var id: Int64
        public var title: String
        public var newTitle: String?
        public var project: String?
        public var newProject: String?
        /// 새로 붙인(붙일) `chatgpt_chat` 위치의 대화 ID.
        public var attachedChat: String?
        /// 제목을 못 고친 이유(고치지 못한 항목에만).
        public var reason: String?
    }

    /// 무언가 바뀐(바뀔) 티켓.
    public var updated: [Entry] = []
    /// 제목에 머리말 흔적이 남았는데 고치지 못한 티켓(이유가 붙는다). 바뀐 게 없어도 매번 나온다.
    public var unresolved: [Entry] = []

    public init() {}
}

/// 이미 쌓인 "참조한 ChatGPT 대화" 머리말 제목을 한 번에 바로잡는다(`docs/01-product/auto-capture.md`).
/// 프롬프트는 DB에 없어서 Codex 세션 기록(rollout)의 첫 프롬프트를 읽기 전용으로 쓴다.
/// 고정한 제목은 건드리지 않는다. 고친 티켓은 후보에서 빠지므로 다시 실행해도 같은 결과다(멱등).
public struct Retitler {
    public static let unresolvedNoThread = "no codex thread"
    public static let unresolvedNoRollout = "session record not found"
    public static let unresolvedNoHeader = "session record has no referenced-conversation prompt"
    public static let unresolvedNoText = "prompt has neither request text nor conversation title"

    private let store: Store
    private let rollout: CodexRollout

    public init(store: Store, codexHome: String) {
        self.store = store
        self.rollout = CodexRollout(codexHome: codexHome)
    }

    /// 제목이 머리말 흔적으로 시작하는가: 머리말 자체, `## My request:`, `Continuing from [..](chatgpt-conversation://..)`.
    public static func hasHeaderRemnant(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReferencedConversation.hasHeader(trimmed) || trimmed.hasPrefix(ReferencedConversation.requestMarker)
            || trimmed.range(of: #"^Continuing from \[.*\]\(chatgpt-conversation://"#, options: .regularExpression) != nil
    }

    @discardableResult
    public func retitle(dryRun: Bool) throws -> RetitleReport {
        dryRun ? try store.rollbackTransaction { try run() } : try store.transaction { try run() }
    }

    private func run() throws -> RetitleReport {
        var report = RetitleReport()
        for ticket in try store.listTickets().sorted(by: { $0.id < $1.id }) {
            let locations = try store.locations(ticketId: ticket.id)
            let threads = locations.compactMap { location -> Locator.CodexThread? in
                if case .codexThread(let thread) = location.locator { return thread }
                return nil
            }
            let remnant = !ticket.pinnedTitle && Self.hasHeaderRemnant(ticket.title)
            let chatGPTFolder = threads.contains { $0.cwd.map(Reconciler.isChatGPTProjectPath) == true }
            // g-p-… 프로젝트는 ChatGPT 프로젝트 폴더 이름이다: 그 폴더에서 돈 세션이거나 머리말 제목일 때만 바로잡고,
            // 프로젝트가 비어 있어도 그 폴더에서 돈 세션이면 채운다.
            let projectFix = ticket.project.map { $0.hasPrefix("g-p-") && (chatGPTFolder || remnant) } ?? chatGPTFolder
            guard remnant || projectFix else { continue }

            var entry = RetitleReport.Entry(id: ticket.id, title: ticket.title, project: ticket.project)
            var reference: ReferencedConversation?
            var failure: String?
            if remnant {
                if threads.isEmpty {
                    failure = Self.unresolvedNoThread
                } else {
                    var sawFile = false
                    for thread in threads {
                        guard let file = rollout.file(forThread: thread.threadId) else { continue }
                        sawFile = true
                        if let found = CodexRollout.referencedConversation(inFile: file) { reference = found; break }
                    }
                    if reference == nil { failure = sawFile ? Self.unresolvedNoHeader : Self.unresolvedNoRollout }
                }
                if let reference, reference.title == nil { failure = Self.unresolvedNoText }
            }

            var changed = false
            if let title = reference?.title, remnant, try store.autoUpdateTitle(id: ticket.id, title: title) {
                entry.newTitle = title
                changed = true
            }
            if projectFix {
                try store.patchTicket(id: ticket.id, TicketPatch(project: .some(Reconciler.chatGPTProject)))
                entry.newProject = Reconciler.chatGPTProject
                changed = true
            }
            if let id = reference?.conversationId, try Reconciler.attachChatGPTChat(conversationId: id, to: ticket.id, store: store) {
                entry.attachedChat = id
                changed = true
            }
            if changed { report.updated.append(entry) }
            if let failure, entry.newTitle == nil {
                entry.reason = failure
                report.unresolved.append(entry)
            }
        }
        return report
    }
}
