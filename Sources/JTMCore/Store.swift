import Foundation
import SQLite3

public enum StoreError: Error, CustomStringConvertible {
    case sqlite(code: Int32, message: String)
    case ticketNotFound(Int64)
    case locationNotFound(Int64)
    case unsupportedSchema(version: Int)
    case corrupt(String)
    case missingExternalKey
    case sessionNotIgnored(String)
    /// 읽기 전용으로 열었는데 아직 마이그레이션되지 않은 DB(쓰기 가능한 `Store`가 한 번 열어야 한다).
    case schemaNotMigrated(version: Int)

    public var description: String {
        switch self {
        case .sqlite(let code, let message): "sqlite error \(code): \(message)"
        case .ticketNotFound(let id): "ticket \(id) not found"
        case .locationNotFound(let id): "location \(id) not found"
        case .unsupportedSchema(let version): "database schema v\(version) is newer than this jtm supports"
        case .corrupt(let detail): "corrupt row: \(detail)"
        case .missingExternalKey: "externalKey must not be empty"
        case .sessionNotIgnored(let key): "session \(key) is not in the ignore list"
        case .schemaNotMigrated(let version): "database schema v\(version) is not migrated yet"
        }
    }
}

/// 새 티켓의 초기값.
public struct NewTicket: Sendable {
    public var title: String
    public var status: TicketStatus
    public var priority: Int?
    public var project: String?
    public var nextAction: String?
    public var note: String?
    public var pinnedTitle: Bool
    public var waitingReason: WaitingReason?
    /// 지정하면 `lastActivityAt`의 초기값(현재 시각을 넘지 않는다). 폴러가 에이전트의 마지막 활동 시각을 넣는다.
    public var lastActivityAt: Date?
    /// 사용자가 직접 만든 티켓(`jtm add`)은 처음부터 유지다.
    public var kept: Bool

    public init(
        title: String, status: TicketStatus = .inbox, priority: Int? = nil, project: String? = nil,
        nextAction: String? = nil, note: String? = nil, pinnedTitle: Bool = false,
        waitingReason: WaitingReason? = nil, lastActivityAt: Date? = nil, kept: Bool = false
    ) {
        self.title = title
        self.status = status
        self.priority = priority
        self.project = project
        self.nextAction = nextAction
        self.note = note
        self.pinnedTitle = pinnedTitle
        self.waitingReason = waitingReason
        self.lastActivityAt = lastActivityAt
        self.kept = kept
    }
}

/// 지정한 컬럼만 바꾸는 부분 갱신. 값이 nil이면 그 컬럼은 건드리지 않고,
/// 지울 수 있는 컬럼(`priority` 등)은 `.some(nil)`로 지운다.
public struct TicketPatch: Sendable {
    public var title: String?
    public var status: TicketStatus?
    public var priority: Int??
    public var project: String??
    public var nextAction: String??
    public var note: String??
    public var pinnedTitle: Bool?
    public var waitingReason: WaitingReason??
    public var endedAt: Date??
    public var kept: Bool?
    /// `.some(nil)`이면 보관을 푼다.
    public var archivedAt: Date??
    /// 자동 완료 표지. `.some(nil)`이면 지운다(재개방, 사용자의 상태 변경).
    public var autoDoneAt: Date??
    /// false면 `status`를 바꿔도 `lastActivityAt`을 올리지 않는다(폴러의 멈춤 표시는 에이전트 활동이 아니다).
    public var bumpsActivity: Bool

    public init(
        title: String? = nil, status: TicketStatus? = nil, priority: Int?? = nil, project: String?? = nil,
        nextAction: String?? = nil, note: String?? = nil, pinnedTitle: Bool? = nil,
        waitingReason: WaitingReason?? = nil, endedAt: Date?? = nil, kept: Bool? = nil, archivedAt: Date?? = nil,
        autoDoneAt: Date?? = nil, bumpsActivity: Bool = true
    ) {
        self.title = title
        self.status = status
        self.priority = priority
        self.project = project
        self.nextAction = nextAction
        self.note = note
        self.pinnedTitle = pinnedTitle
        self.waitingReason = waitingReason
        self.endedAt = endedAt
        self.kept = kept
        self.archivedAt = archivedAt
        self.autoDoneAt = autoDoneAt
        self.bumpsActivity = bumpsActivity
    }

    /// 사용자가 직접 한 수정인가("유지"가 되는 편집): 제목, next_action, note, priority, project를 고치거나
    /// 상태를 직접 바꾼다(`done`은 제외, `blocked`는 포함: 사용자만 고르는 상태다).
    /// 자동 수집(훅, 폴러)은 이 패치를 쓰지 않는다 — `Store.patchTicketAsUser`만 이 값으로 `kept`를 올린다.
    public var impliesKeep: Bool {
        title != nil || nextAction != nil || note != nil || priority != nil || project != nil
            || (status != nil && status != .done)
    }
}

/// 메뉴바 앱이 한 번에 읽는 티켓과 그 위치들.
public struct TicketListing: Sendable, Equatable {
    public var ticket: Ticket
    public var locations: [Location]

    public init(ticket: Ticket, locations: [Location]) {
        self.ticket = ticket
        self.locations = locations
    }
}

/// SQLite 저장소. 시각은 모두 unix seconds(INTEGER)로 저장한다.
/// 경로는 호출자가 정한다(CLI는 env/기본 경로, 테스트는 임시 경로).
/// 스레드 간 공유하지 않는다: 스레드/프로세스마다 자기 `Store`를 연다(동시 접근은 WAL + busy_timeout이 직렬화한다).
public final class Store {
    private static let schemaVersion = 6
    /// 이 시간 동안 활동이 없는 유지 안 한 티켓은 보관함으로 간다.
    public static let archiveAfter: TimeInterval = 24 * 3_600
    /// 사용자가 무시한 세션을 `ignored_sessions`에 남길 때의 사유.
    public static let userIgnoredReason = "user-ignored"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var db: OpaquePointer?
    private let now: () -> Date
    private let warn: (String) -> Void
    private var transactionDepth = 0

    public init(
        path: String, now: @escaping () -> Date = Date.init,
        onWarning: @escaping (String) -> Void = { FileHandle.standardError.write(Data("warning: \($0)\n".utf8)) }
    ) throws {
        self.now = now
        self.warn = onWarning
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            // 새로 만드는 폴더만 0700이다(이미 있는 폴더의 권한은 바꾸지 않는다).
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        Self.securePermissions(ofDatabaseAt: path)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        // 실패해도 핸들은 deinit이 한 번만 닫는다(여기서 닫으면 이중 close).
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else { throw lastError() }
        // foreign_keys는 커넥션 단위 설정이라 열 때마다 켠다. busy_timeout을 먼저 걸어야 WAL 전환도 경합에 안전하다.
        // 훅의 2초 예산 안에 끝나도록 대기는 1초로 제한한다.
        try exec("PRAGMA busy_timeout=1000")
        try enableWAL()
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA foreign_keys=ON")
        try migrate()
    }

    /// 읽기 전용 연결(메뉴바 앱의 목록 갱신용). 파일을 만들거나 권한·스키마를 건드리지 않고, 쓰기 잠금을 잡지 않으므로
    /// WAL 모드에서 훅의 쓰기를 막지 않는다. 파일이 없으면 열리지 않고, 마이그레이션 전이면 `schemaNotMigrated`를 던진다.
    public init(
        readOnlyPath path: String, now: @escaping () -> Date = Date.init,
        onWarning: @escaping (String) -> Void = { FileHandle.standardError.write(Data("warning: \($0)\n".utf8)) }
    ) throws {
        self.now = now
        self.warn = onWarning
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw lastError()
        }
        try exec("PRAGMA busy_timeout=1000")
        let version = try userVersion()
        guard version <= Self.schemaVersion else { throw StoreError.unsupportedSchema(version: version) }
        guard version == Self.schemaVersion else { throw StoreError.schemaNotMigrated(version: version) }
    }

    deinit { sqlite3_close_v2(db) }

    /// DB에는 프롬프트 앞부분과 작업 경로가 있으므로 본인만 읽게 한다(0600). SQLite는 새 파일을 0644로 만들고
    /// `-wal`/`-shm`은 본 파일의 권한을 따르므로, 열기 전에 0600으로 미리 만들고 이미 있는 느슨한 파일은 조인다.
    /// 일반 파일이 아니거나(디렉터리, 장치) 만들 수 없으면 아무것도 하지 않고 SQLite가 알아서 실패하게 둔다.
    private static func securePermissions(ofDatabaseAt path: String) {
        guard !path.isEmpty, path != ":memory:", !path.hasPrefix("file:") else { return }
        let descriptor = open(path, O_RDWR | O_CREAT | O_NONBLOCK, 0o600)
        if descriptor >= 0 { close(descriptor) }
        for suffix in ["", "-wal", "-shm"] {
            var info = stat()
            guard lstat(path + suffix, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_mode & 0o077 != 0 else { continue }
            chmod(path + suffix, 0o600)
        }
    }

    // MARK: Transactions

    /// 같은 쓰기 잠금 아래서 `body`를 실행하고 **항상 롤백한다**(`--dry-run`: 실제로 써 보고 결과만 얻는다).
    public func rollbackTransaction<T>(_ body: () throws -> T) throws -> T {
        precondition(transactionDepth == 0, "rollbackTransaction cannot nest")
        try exec("BEGIN IMMEDIATE")
        transactionDepth += 1
        defer { transactionDepth -= 1; try? exec("ROLLBACK") }
        return try body()
    }

    /// `BEGIN IMMEDIATE`로 쓰기 잠금을 먼저 잡고 실행한다. 예외가 나면 롤백한다. 중첩 호출은 바깥 트랜잭션에 합류한다.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 { return try body() }
        try exec("BEGIN IMMEDIATE")
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// 읽기 전용 스냅샷 트랜잭션(쓰기 잠금 없음). 안에서 읽은 것들은 서로 일관된다. 중첩하면 바깥 트랜잭션에 합류한다.
    private func readTransaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 { return try body() }
        try exec("BEGIN")
        transactionDepth += 1
        defer { transactionDepth -= 1; try? exec("ROLLBACK") }
        return try body()
    }

    /// 다른 커넥션이 커밋할 때마다 바뀌는 값(`PRAGMA data_version`). 이 커넥션 자신의 쓰기로는 바뀌지 않는다.
    /// 앱이 2초마다 "훅/CLI가 DB를 바꿨나"를 싸게 확인하는 데 쓴다.
    public func dataVersion() throws -> Int64 {
        try query("PRAGMA data_version", []) { $0.int(0) }[0]
    }

    /// 메뉴바 목록용: done이 아닌 모든 티켓 + `doneSince` 이후 활동한 done 티켓, 각각의 위치. 한 번의 읽기 트랜잭션으로 읽는다.
    /// 정렬은 `listTickets`와 같다(waiting, active, inbox, blocked, done → 최근 활동순).
    public func menuListing(doneSince: Date) throws -> [TicketListing] {
        let predicate = "(status != 'done' OR last_activity_at >= ?)"
        let cutoff = SQLValue.int(timestamp(doneSince))
        return try readTransaction {
            let tickets = try queryLenient(
                """
                SELECT \(Self.ticketColumns) FROM tickets WHERE \(predicate)
                ORDER BY CASE status WHEN 'waiting' THEN 0 WHEN 'active' THEN 1 WHEN 'inbox' THEN 2
                                     WHEN 'blocked' THEN 3 ELSE 4 END,
                         last_activity_at DESC, id DESC
                """, [cutoff], ticket)
            let locations = try queryLenient(
                """
                SELECT \(Self.locationColumns) FROM locations
                WHERE ticket_id IN (SELECT id FROM tickets WHERE \(predicate)) ORDER BY id
                """, [cutoff], location)
            let byTicket = Dictionary(grouping: locations, by: \.ticketId)
            return tickets.map { TicketListing(ticket: $0, locations: byTicket[$0.id] ?? []) }
        }
    }

    // MARK: Tickets

    public func createTicket(
        title: String, status: TicketStatus = .inbox, priority: Int? = nil,
        project: String? = nil, nextAction: String? = nil, note: String? = nil, pinnedTitle: Bool = false,
        kept: Bool = false
    ) throws -> Ticket {
        try createTicket(NewTicket(
            title: title, status: status, priority: priority, project: project,
            nextAction: nextAction, note: note, pinnedTitle: pinnedTitle, kept: kept))
    }

    public func createTicket(_ new: NewTicket) throws -> Ticket {
        let stamp = timestamp(now())
        let ids = try query(
            """
            INSERT INTO tickets (title, status, priority, project, next_action, note, pinned_title,
                                 created_at, updated_at, last_activity_at, waiting_reason, kept)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            RETURNING id
            """,
            [.text(new.title), .text(new.status.rawValue), .int(new.priority.map(Int64.init)),
             .text(new.project), .text(new.nextAction), .text(new.note), .int(new.pinnedTitle ? 1 : 0),
             .int(stamp), .int(stamp), .int(min(new.lastActivityAt.map(timestamp) ?? stamp, stamp)),
             .text(new.waitingReason?.rawValue), .int(new.kept ? 1 : 0)]
        ) { $0.int(0) }
        return try getTicket(id: ids[0])
    }

    /// 전체 행을 덮어쓴다. 오래된 스냅샷으로 동시 변경을 되돌릴 수 있으므로 테스트/일회성 용도로만 쓴다
    /// (CLI와 리졸버는 `patchTicket`/`touchActivity`를 쓴다). `lastActivityAt`은 전달된 값 그대로다.
    @discardableResult
    public func updateTicket(_ ticket: Ticket) throws -> Ticket {
        let rows = try query(
            """
            UPDATE tickets SET title = ?, status = ?, priority = ?, project = ?, next_action = ?,
                               note = ?, pinned_title = ?, last_activity_at = ?, updated_at = ?,
                               waiting_reason = ?, ended_at = ?, kept = ?, archived_at = ?, auto_done_at = ?
            WHERE id = ? RETURNING id
            """,
            [.text(ticket.title), .text(ticket.status.rawValue), .int(ticket.priority.map(Int64.init)),
             .text(ticket.project), .text(ticket.nextAction), .text(ticket.note),
             .int(ticket.pinnedTitle ? 1 : 0), .int(timestamp(ticket.lastActivityAt)),
             .int(timestamp(now())), .text(ticket.waitingReason?.rawValue),
             .int(ticket.endedAt.map(timestamp)), .int(ticket.kept ? 1 : 0),
             .int(ticket.archivedAt.map(timestamp)), .int(ticket.autoDoneAt.map(timestamp)), .int(ticket.id)]
        ) { $0.int(0) }
        guard !rows.isEmpty else { throw StoreError.ticketNotFound(ticket.id) }
        return try getTicket(id: ticket.id)
    }

    /// 지정한 컬럼만 바꾼다(다른 프로세스의 동시 변경을 덮어쓰지 않는다). 항상 `updatedAt`을 갱신하고,
    /// `status`를 바꿀 때만 `lastActivityAt`도 올린다(lastActivityAt = 에이전트 활동 + 상태 변경).
    @discardableResult
    public func patchTicket(id: Int64, _ patch: TicketPatch = TicketPatch()) throws -> Ticket {
        var assignments: [String] = []
        var params: [SQLValue] = []
        func assign(_ column: String, _ value: SQLValue) {
            assignments.append("\(column) = ?")
            params.append(value)
        }
        if let title = patch.title { assign("title", .text(title)) }
        if let status = patch.status { assign("status", .text(status.rawValue)) }
        if let priority = patch.priority { assign("priority", .int(priority.map(Int64.init))) }
        if let project = patch.project { assign("project", .text(project)) }
        if let nextAction = patch.nextAction { assign("next_action", .text(nextAction)) }
        if let note = patch.note { assign("note", .text(note)) }
        if let pinned = patch.pinnedTitle { assign("pinned_title", .int(pinned ? 1 : 0)) }
        if let reason = patch.waitingReason {
            assign("waiting_reason", .text(reason?.rawValue))
        } else if patch.status != nil {
            // 상태를 바꾸면서 이유를 따로 주지 않으면 이전 이유는 더는 유효하지 않다(예: `jtm done`, `set --status active`).
            assign("waiting_reason", .null)
        }
        if let endedAt = patch.endedAt { assign("ended_at", .int(endedAt.map(timestamp))) }
        if let kept = patch.kept { assign("kept", .int(kept ? 1 : 0)) }
        if let archivedAt = patch.archivedAt {
            assign("archived_at", .int(archivedAt.map(timestamp)))
        } else if patch.status == .done {
            // done인 티켓은 보관 대상이 아니다(보관함에는 끝나지 않은 것만 있다): 어느 경로로 done이 돼도 보관을 푼다.
            assign("archived_at", .null)
        }
        if let autoDoneAt = patch.autoDoneAt { assign("auto_done_at", .int(autoDoneAt.map(timestamp))) }
        let stamp = timestamp(now())
        assign("updated_at", .int(stamp))
        if patch.status != nil, patch.bumpsActivity {
            assignments.append("last_activity_at = MAX(last_activity_at, ?)")
            params.append(.int(stamp))
        }
        params.append(.int(id))
        let rows = try query(
            "UPDATE tickets SET \(assignments.joined(separator: ", ")) WHERE id = ? RETURNING id", params
        ) { $0.int(0) }
        guard !rows.isEmpty else { throw StoreError.ticketNotFound(id) }
        return try getTicket(id: id)
    }

    /// 에이전트 활동을 기록한다. `lastActivityAt`은 뒤로 가지 않고, 보관 중이었다면 보관을 푼다(새 활동 = 다시 보인다).
    @discardableResult
    public func touchActivity(id: Int64, at date: Date? = nil) throws -> Ticket {
        let stamp = timestamp(date ?? now())
        let rows = try query(
            "UPDATE tickets SET last_activity_at = MAX(last_activity_at, ?), updated_at = ?, archived_at = NULL WHERE id = ? RETURNING id",
            [.int(stamp), .int(timestamp(now())), .int(id)]
        ) { $0.int(0) }
        guard !rows.isEmpty else { throw StoreError.ticketNotFound(id) }
        return try getTicket(id: id)
    }

    /// 사용자가 직접 한 수정(CLI `set`, 팝오버의 편집/상태 변경). `TicketPatch.impliesKeep`이면 티켓이 "유지"가 된다.
    /// 유지가 되거나 상태를 바꾸면 보관도 풀린다(사용자가 손댄 티켓이 보관함에 남아 있지 않게).
    /// 훅과 폴러는 `patchTicket`을 직접 쓴다: 자동 수집은 `kept`를 올리지 않는다.
    @discardableResult
    public func patchTicketAsUser(id: Int64, _ patch: TicketPatch) throws -> Ticket {
        var patch = patch
        if patch.impliesKeep { patch.kept = true }
        if patch.kept == true || patch.status != nil { patch.archivedAt = .some(nil) }
        // 사용자가 상태를 바꿨다: done이든 되살리든 더는 "자동 완료"가 아니다(자동 재개방 대상에서 빠진다).
        if patch.status != nil { patch.autoDoneAt = .some(nil) }
        return try patchTicket(id: id, patch)
    }

    /// ⭐ 토글(`jtm keep|unkeep`). 유지로 만들면 보관도 푼다. `updatedAt`만 바꾸고 활동 시간은 건드리지 않는다.
    @discardableResult
    public func setKept(id: Int64, _ kept: Bool) throws -> Ticket {
        try patchTicket(id: id, TicketPatch(kept: kept, archivedAt: kept ? .some(nil) : nil))
    }

    /// 보관함에서 되살린다: 보관을 풀고 유지로 만든다(다음 자동 보관을 받지 않게). 보관 중이 아니어도 유지가 된다.
    @discardableResult
    public func restoreTicket(id: Int64) throws -> Ticket {
        try patchTicket(id: id, TicketPatch(kept: true, archivedAt: .some(nil)))
    }

    /// 자동 보관: 유지가 아니고 done이 아니며 `archiveAfter` 동안 활동이 없는 티켓을 보관함으로 보낸다(상태는 그대로).
    /// 한 번의 UPDATE다. 보관한 티켓 수를 돌려준다.
    @discardableResult
    public func archiveStale(now: Date? = nil) throws -> Int {
        let current = timestamp(now ?? self.now())
        return try query(
            """
            UPDATE tickets SET archived_at = ?
            WHERE kept = 0 AND status != 'done' AND archived_at IS NULL AND last_activity_at < ?
            RETURNING id
            """,
            [.int(current), .int(current - Int64(Self.archiveAfter))]
        ) { $0.int(0) }.count
    }

    /// 무시(🗑, `jtm ignore`)가 한 일.
    public struct IgnoreResult: Equatable, Sendable {
        /// 무시 목록(`ignored_sessions`)에 올린 세션 키(`claude:…`, `codex:…`).
        public var sessionKeys: [String]
        /// 폴러가 다시 티켓을 만들지 않도록 표시한 Orca 탭.
        public var tabIds: [String]
    }

    /// 티켓을 지우고 그 티켓의 세션 키를 무시 목록에 올린다(사유 `user-ignored`): 같은 세션은 다시 생기지 않는다.
    /// `orca-tab:` 키는 무시 목록에 넣지 않는다: 같은 탭의 **새 세션**은 새 티켓으로 나타나야 한다.
    /// 다만 폴러는 에이전트가 `worktree ps`에 남아 있는 동안 탭만 보고 inbox 티켓을 다시 만들 수 있어서,
    /// 이 티켓의 탭은 따로 표시해 둔다(`ignoredOrcaTabs`): 탭이 사라지거나 새 세션이 훅으로 탭을 가져가면 풀린다.
    @discardableResult
    public func ignoreTicket(id: Int64) throws -> IgnoreResult {
        try transaction {
            _ = try getTicket(id: id)
            let locations = try self.locations(ticketId: id)
            let keys = OrcaWorker.sessionKeys(of: locations)
            for key in keys { try ignoreSession(key, reason: Self.userIgnoredReason) }
            let tabs = locations.compactMap { location -> String? in
                guard let key = location.externalKey, key.hasPrefix(Self.orcaTabPrefix) else { return nil }
                return String(key.dropFirst(Self.orcaTabPrefix.count))
            }
            for tab in tabs { try ignoreOrcaTab(tab) }
            try deleteTicket(id: id)
            return IgnoreResult(sessionKeys: keys, tabIds: tabs)
        }
    }

    static let orcaTabPrefix = "orca-tab:"
    private static let ignoredTabPrefix = "ignored-tab:"

    /// 이 탭의 티켓을 사용자가 무시했다고 표시한다(값: `<시각>:<연속 미발견 횟수>`). 이미 표시돼 있으면 횟수를 0으로 되돌린다.
    public func ignoreOrcaTab(_ tabId: String) throws {
        guard !tabId.isEmpty else { return }
        try exec(
            "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(Self.ignoredTabPrefix + tabId), .text("\(timestamp(now())):0")])
    }

    /// 무시 표시된 탭들과 각 탭을 스냅샷에서 연속으로 못 찾은 횟수.
    public func ignoredOrcaTabs() throws -> [String: Int] {
        var found: [String: Int] = [:]
        let rows = try query(
            "SELECT key, value FROM meta WHERE substr(key, 1, ?) = ?",
            [.int(Int64(Self.ignoredTabPrefix.count)), .text(Self.ignoredTabPrefix)]
        ) { ($0.text(0) ?? "", $0.text(1) ?? "") }
        for (key, value) in rows {
            found[String(key.dropFirst(Self.ignoredTabPrefix.count))] = Int(value.split(separator: ":").last ?? "0") ?? 0
        }
        return found
    }

    /// 무시 표시된 탭의 연속 미발견 횟수를 바꾼다(`nil`이면 표시를 지운다).
    public func setIgnoredOrcaTabMisses(_ tabId: String, misses: Int?) throws {
        let key = Self.ignoredTabPrefix + tabId
        guard let misses else {
            try exec("DELETE FROM meta WHERE key = ?", [.text(key)])
            return
        }
        try exec(
            "UPDATE meta SET value = substr(value, 1, instr(value, ':')) || ? WHERE key = ?",
            [.text(String(misses)), .text(key)])
    }

    public func clearIgnoredOrcaTab(_ tabId: String) throws { try setIgnoredOrcaTabMisses(tabId, misses: nil) }

    /// 표시한 지 `interval`이 지난 무시 표시를 지운다. 지운 수.
    @discardableResult
    public func expireIgnoredOrcaTabs(olderThan interval: TimeInterval, now: Date? = nil) throws -> Int {
        let cutoff = timestamp(now ?? self.now()) - Int64(interval)
        return try query(
            """
            DELETE FROM meta WHERE substr(key, 1, ?) = ?
              AND CAST(substr(value, 1, instr(value, ':') - 1) AS INTEGER) < ?
            RETURNING 1
            """,
            [.int(Int64(Self.ignoredTabPrefix.count)), .text(Self.ignoredTabPrefix), .int(cutoff)]
        ) { $0.int(0) }.count
    }

    /// 자동 수집(세션/터미널 제목)이 제목을 갱신할 때 쓴다. 사용자가 고정한 제목이거나 빈 제목이면 아무것도 하지 않는다.
    /// 실제로 바꿨으면 true.
    @discardableResult
    public func autoUpdateTitle(id: Int64, title: String) throws -> Bool {
        _ = try getTicket(id: id)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let rows = try query(
            "UPDATE tickets SET title = ?, updated_at = ? WHERE id = ? AND pinned_title = 0 RETURNING id",
            [.text(title), .int(timestamp(now())), .int(id)]
        ) { $0.int(0) }
        return !rows.isEmpty
    }

    /// 티켓을 지운다(위치는 `ON DELETE CASCADE`로 함께 지워진다). 지웠으면 true, 원래 없었으면 false.
    @discardableResult
    public func deleteTicket(id: Int64) throws -> Bool {
        !(try query("DELETE FROM tickets WHERE id = ? RETURNING id", [.int(id)]) { $0.int(0) }).isEmpty
    }

    public func getTicket(id: Int64) throws -> Ticket {
        let rows = try query("SELECT \(Self.ticketColumns) FROM tickets WHERE id = ?", [.int(id)], ticket)
        guard let found = rows.first else { throw StoreError.ticketNotFound(id) }
        return found
    }

    /// 보관된 티켓을 목록에 넣을지.
    public enum ArchiveScope: Sendable { case all, excludingArchived, onlyArchived }

    /// `statuses`가 nil이면 전부(보관된 것도: `archive`로 거른다). 정렬: waiting, active, inbox, blocked, done 순 → 그룹 안에서는 lastActivityAt 최신순.
    /// 알 수 없는 status가 든 행은 경고만 남기고 건너뛴다.
    public func listTickets(statuses: Set<TicketStatus>? = nil, archive: ArchiveScope = .all) throws -> [Ticket] {
        var conditions: [String] = []
        var params: [SQLValue] = []
        if let statuses {
            conditions.append("status IN (\(statuses.map { _ in "?" }.joined(separator: ", ")))")
            params = statuses.map { .text($0.rawValue) }
        }
        switch archive {
        case .all: break
        case .excludingArchived: conditions.append("archived_at IS NULL")
        case .onlyArchived: conditions.append("archived_at IS NOT NULL")
        }
        var sql = "SELECT \(Self.ticketColumns) FROM tickets"
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += """
             ORDER BY CASE status WHEN 'waiting' THEN 0 WHEN 'active' THEN 1 WHEN 'inbox' THEN 2
                                  WHEN 'blocked' THEN 3 ELSE 4 END,
                      last_activity_at DESC, id DESC
            """
        return try queryLenient(sql, params, ticket)
    }

    // MARK: Locations

    @discardableResult
    public func addLocation(
        ticketId: Int64, locator: Locator, source: LocationSource, externalKey: String? = nil
    ) throws -> Location {
        let ids = try query(
            """
            INSERT INTO locations (ticket_id, kind, locator, source, external_key, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?)
            RETURNING id
            """,
            [.int(ticketId), .text(locator.kind.rawValue), .text(try json(locator)),
             .text(source.rawValue), .text(externalKey), .int(timestamp(now()))]
        ) { $0.int(0) }
        return try location(id: ids[0])
    }

    /// 알 수 없는 kind/source가 든 행은 경고만 남기고 건너뛴다.
    public func locations(ticketId: Int64) throws -> [Location] {
        try queryLenient(
            "SELECT \(Self.locationColumns) FROM locations WHERE ticket_id = ? ORDER BY id",
            [.int(ticketId)], location)
    }

    /// 키가 `prefix`로 시작하는 모든 위치(예: `orca-tab:`). 알 수 없는 kind/source가 든 행은 경고만 남기고 건너뛴다.
    public func locations(externalKeyPrefix prefix: String) throws -> [Location] {
        try queryLenient(
            "SELECT \(Self.locationColumns) FROM locations WHERE substr(external_key, 1, ?) = ? ORDER BY id",
            [.int(Int64(prefix.count)), .text(prefix)], location)
    }

    public func location(byExternalKey externalKey: String) throws -> Location? {
        try query(
            "SELECT \(Self.locationColumns) FROM locations WHERE external_key = ?",
            [.text(externalKey)], location
        ).first
    }

    /// 위치의 locator만 바꾼다(예: 갱신된 Orca handle 저장). `lastSeenAt`은 건드리지 않는다.
    @discardableResult
    public func updateLocation(id: Int64, locator: Locator) throws -> Location {
        let rows = try query(
            "UPDATE locations SET kind = ?, locator = ? WHERE id = ? RETURNING id",
            [.text(locator.kind.rawValue), .text(try json(locator)), .int(id)]
        ) { $0.int(0) }
        guard !rows.isEmpty else { throw StoreError.locationNotFound(id) }
        return try location(id: id)
    }

    /// `externalKey`가 이미 있으면 그 행의 locator/lastSeenAt만 갱신하고(티켓 소속과 최초 `source`는 유지), 없으면 `ticketId`에 새로 붙인다.
    @discardableResult
    public func upsertLocation(
        byExternalKey externalKey: String, ticketId: Int64, locator: Locator, source: LocationSource
    ) throws -> Location {
        // UNIQUE는 NULL 중복을 허용하므로 빈 키를 막지 않으면 조용히 중복이 쌓인다.
        guard !externalKey.isEmpty else { throw StoreError.missingExternalKey }
        let ids = try query(
            """
            INSERT INTO locations (ticket_id, kind, locator, source, external_key, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(external_key) DO UPDATE SET
                kind = excluded.kind, locator = excluded.locator, last_seen_at = excluded.last_seen_at,
                gone_at = NULL, miss_count = 0
            RETURNING id
            """,
            [.int(ticketId), .text(locator.kind.rawValue), .text(try json(locator)),
             .text(source.rawValue), .text(externalKey), .int(timestamp(now()))]
        ) { $0.int(0) }
        return try location(id: ids[0])
    }

    /// 위치를 다른 티켓으로 옮긴다(같은 탭에서 새 세션이 시작됐을 때 `orca-tab:` 위치가 최신 세션의 티켓을 따라간다).
    /// locator와 `lastSeenAt`은 그대로다. 대상 티켓이 없으면 `ticketNotFound`, 위치가 없으면 `locationNotFound`.
    @discardableResult
    public func moveLocation(id: Int64, toTicketId ticketId: Int64) throws -> Location {
        try transaction {
            _ = try getTicket(id: ticketId)
            let rows = try query(
                "UPDATE locations SET ticket_id = ? WHERE id = ? RETURNING id", [.int(ticketId), .int(id)]
            ) { $0.int(0) }
            guard !rows.isEmpty else { throw StoreError.locationNotFound(id) }
            return try location(id: id)
        }
    }

    /// 폴러가 이 위치를 못 찾은 연속 횟수를 하나 올리고 새 값을 돌려준다(`upsertLocation`이 다시 보이면 0으로 되돌린다).
    @discardableResult
    public func recordLocationMiss(id: Int64) throws -> Int {
        let rows = try query(
            "UPDATE locations SET miss_count = miss_count + 1 WHERE id = ? RETURNING miss_count", [.int(id)]
        ) { $0.int(0) }
        guard let count = rows.first else { throw StoreError.locationNotFound(id) }
        return Int(count)
    }

    /// 폴러가 위치를 더는 찾지 못했을 때의 표시. `nil`이면 다시 살아난 것으로 지운다. 티켓 상태는 건드리지 않는다.
    @discardableResult
    public func setLocationGone(id: Int64, at date: Date?) throws -> Location {
        let rows = try query(
            "UPDATE locations SET gone_at = ? WHERE id = ? RETURNING id",
            [.int(date.map(timestamp)), .int(id)]
        ) { $0.int(0) }
        guard !rows.isEmpty else { throw StoreError.locationNotFound(id) }
        return try location(id: id)
    }

    /// 훅/폴러용 원자적 get-or-create: `externalKey`의 위치가 있으면 그 티켓에 대해 locator/lastSeenAt만 갱신하고,
    /// 없으면 한 트랜잭션 안에서 티켓과 위치를 함께 만든다. 같은 키로 몇 번을 불러도 티켓은 하나다.
    /// `lastActivityAt`은 건드리지 않는다(활동 기록은 `touchActivity`).
    public func upsertTicketAndLocation(
        externalKey: String, locator: Locator, source: LocationSource, newTicket: NewTicket
    ) throws -> (ticket: Ticket, location: Location, created: Bool) {
        guard !externalKey.isEmpty else { throw StoreError.missingExternalKey }
        return try transaction {
            if let existing = try location(byExternalKey: externalKey) {
                let refreshed = try upsertLocation(
                    byExternalKey: externalKey, ticketId: existing.ticketId, locator: locator, source: source)
                return (try getTicket(id: existing.ticketId), refreshed, false)
            }
            let ticket = try createTicket(newTicket)
            let created = try addLocation(
                ticketId: ticket.id, locator: locator, source: source, externalKey: externalKey)
            return (ticket, created, true)
        }
    }

    // MARK: Ignored sessions / worker handles / meta

    /// 이 세션 키(`claude:<id>`, `codex:<id>`)는 수집하지 않는다고 기록돼 있는가. 훅마다 한 번 묻는다(기본 키 조회).
    public func isSessionIgnored(_ externalKey: String) throws -> Bool {
        !(try query("SELECT 1 FROM ignored_sessions WHERE external_key = ?", [.text(externalKey)]) { $0.int(0) }).isEmpty
    }

    /// 세션을 수집 대상에서 뺀다. 이미 있으면 처음 기록(이유, 시각)을 유지한다.
    public func ignoreSession(_ externalKey: String, reason: String) throws {
        guard !externalKey.isEmpty else { throw StoreError.missingExternalKey }
        try exec(
            "INSERT OR IGNORE INTO ignored_sessions (external_key, reason, created_at) VALUES (?, ?, ?)",
            [.text(externalKey), .text(reason), .int(timestamp(now()))])
    }

    /// 무시하기로 한 세션의 키와 이유(키 순).
    public func ignoredSessions() throws -> [(externalKey: String, reason: String?)] {
        try query("SELECT external_key, reason FROM ignored_sessions ORDER BY external_key", []) {
            ($0.text(0) ?? "", $0.text(1))
        }
    }

    /// 무시 목록에서 뺀다(잘못 무시한 세션을 다시 수집하게 한다). 있었으면 true. 이미 지워진 티켓은 돌아오지 않고,
    /// 그 세션의 다음 훅 이벤트부터 새 티켓으로 잡힌다.
    @discardableResult
    public func unignoreSession(_ externalKey: String) throws -> Bool {
        !(try query("DELETE FROM ignored_sessions WHERE external_key = ? RETURNING 1", [.text(externalKey)]) { $0.int(0) }).isEmpty
    }

    /// 무시한 세션의 사유(무시 목록에 없거나 사유가 비어 있으면 nil).
    public func ignoredSessionReason(_ externalKey: String) throws -> String? {
        try query("SELECT reason FROM ignored_sessions WHERE external_key = ?", [.text(externalKey)]) { $0.text(0) }.first ?? nil
    }

    /// 무시한 세션의 키, 사유, 기록 시각(키 순).
    public func ignoredSessionRecords() throws -> [(externalKey: String, reason: String?, createdAt: Date?)] {
        try query("SELECT external_key, reason, created_at FROM ignored_sessions ORDER BY external_key", []) {
            ($0.text(0) ?? "", $0.text(1), $0.optionalInt(2).map(date))
        }
    }

    // MARK: Codex sessions whose rollout file is missing (undecided)

    static let codexUndecidedPrefix = "codex-undecided:"
    /// 판단을 못 한 채 이만큼 지난 기록은 정리한다(일회성 내부 작업이 남기는 찌꺼기).
    static let codexUndecidedKeep: TimeInterval = 24 * 3_600

    /// 기록 파일이 아직 없어 판단하지 못한 Codex 세션의 메모.
    public struct CodexUndecided: Equatable, Sendable {
        /// 처음 "파일 없음"을 본 시각.
        public var firstSeen: Date
        /// 그때 본 프롬프트 제목(나중에 사용자 세션으로 판명되면 티켓 제목으로 쓴다).
        public var title: String?
    }

    /// "파일 없음"을 봤다고 적는다. 이미 있으면 처음 시각을 유지하고(제목이 비어 있었으면 채운다) 그 메모를 돌려준다.
    /// 오래된 메모는 같은 문장에서 정리한다.
    @discardableResult
    public func noteCodexUndecided(_ sessionKey: String, title: String?) throws -> CodexUndecided {
        let key = Self.codexUndecidedPrefix + sessionKey
        let current = timestamp(now())
        try exec(
            """
            DELETE FROM meta WHERE substr(key, 1, ?) = ?
              AND CAST(substr(value, 1, instr(value, '|') - 1) AS INTEGER) < ?
            """,
            [.int(Int64(Self.codexUndecidedPrefix.count)), .text(Self.codexUndecidedPrefix),
             .int(current - Int64(Self.codexUndecidedKeep))])
        if let known = try codexUndecided(sessionKey) {
            guard known.title == nil, let title, !title.isEmpty else { return known }
            try setMeta(key, "\(timestamp(known.firstSeen))|\(title)")
            return CodexUndecided(firstSeen: known.firstSeen, title: title)
        }
        try setMeta(key, "\(current)|\(title ?? "")")
        return CodexUndecided(firstSeen: date(current), title: title.flatMap { $0.isEmpty ? nil : $0 })
    }

    public func codexUndecided(_ sessionKey: String) throws -> CodexUndecided? {
        guard let value = try meta(Self.codexUndecidedPrefix + sessionKey) else { return nil }
        let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first.flatMap({ Int64($0) }) else { return nil }
        let title = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        return CodexUndecided(firstSeen: date(first), title: title)
    }

    public func clearCodexUndecided(_ sessionKey: String) throws {
        try exec("DELETE FROM meta WHERE key = ?", [.text(Self.codexUndecidedPrefix + sessionKey)])
    }

    public func isOrcaWorkerHandle(_ handle: String) throws -> Bool {
        !(try query("SELECT 1 FROM orca_worker_handles WHERE handle = ?", [.text(handle)]) { $0.int(0) }).isEmpty
    }

    public func orcaWorkerHandles() throws -> Set<String> {
        Set(try query("SELECT handle FROM orca_worker_handles", []) { $0.text(0) ?? "" })
    }

    /// 워커 터미널 handle을 기록한다(이미 있으면 `seen_at`만 갱신하고, 새 `run_id`가 있을 때만 바꾼다).
    public func upsertOrcaWorkerHandle(_ handle: String, runId: String?) throws {
        guard !handle.isEmpty else { return }
        try exec(
            """
            INSERT INTO orca_worker_handles (handle, run_id, seen_at) VALUES (?, ?, ?)
            ON CONFLICT(handle) DO UPDATE SET run_id = COALESCE(excluded.run_id, run_id), seen_at = excluded.seen_at
            """,
            [.text(handle), .text(runId), .int(timestamp(now()))])
    }

    public func meta(_ key: String) throws -> String? {
        try query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { $0.text(0) }.first ?? nil
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try exec(
            "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)])
    }

    // MARK: Row mapping

    private static let ticketColumns =
        "id, title, status, priority, project, next_action, note, pinned_title, created_at, updated_at, last_activity_at, waiting_reason, ended_at, kept, archived_at, auto_done_at"
    private static let locationColumns = "id, ticket_id, kind, locator, source, external_key, last_seen_at, gone_at, miss_count"

    private func ticket(_ row: Row) throws -> Ticket {
        guard let status = TicketStatus(rawValue: row.text(2) ?? "") else {
            throw StoreError.corrupt("ticket \(row.int(0)) has unknown status")
        }
        return Ticket(
            id: row.int(0), title: row.text(1) ?? "", status: status,
            priority: row.optionalInt(3).map(Int.init), project: row.text(4),
            nextAction: row.text(5), note: row.text(6), pinnedTitle: row.int(7) != 0,
            createdAt: date(row.int(8)), updatedAt: date(row.int(9)), lastActivityAt: date(row.int(10)),
            waitingReason: row.text(11).flatMap(WaitingReason.init(rawValue:)),
            endedAt: row.optionalInt(12).map(date), kept: row.int(13) != 0, archivedAt: row.optionalInt(14).map(date),
            autoDoneAt: row.optionalInt(15).map(date))
    }

    private func location(id: Int64) throws -> Location {
        try query("SELECT \(Self.locationColumns) FROM locations WHERE id = ?", [.int(id)], location)[0]
    }

    private func location(_ row: Row) throws -> Location {
        guard let kind = LocationKind(rawValue: row.text(2) ?? ""),
              let source = LocationSource(rawValue: row.text(4) ?? "")
        else { throw StoreError.corrupt("location \(row.int(0)) has unknown kind or source") }
        return Location(
            id: row.int(0), ticketId: row.int(1),
            locator: try Locator(kind: kind, json: Data((row.text(3) ?? "").utf8)),
            source: source, externalKey: row.text(5), lastSeenAt: date(row.int(6)),
            goneAt: row.optionalInt(7).map(date), missCount: Int(row.int(8)))
    }

    private func json(_ locator: Locator) throws -> String {
        String(decoding: try locator.jsonData(), as: UTF8.self)
    }

    private func timestamp(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }
    private func date(_ timestamp: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }

    // MARK: Migrations

    private func userVersion() throws -> Int {
        Int(try query("PRAGMA user_version", []) { $0.int(0) }[0])
    }

    /// 확인 → 쓰기 잠금 → 재확인. 여러 프로세스가 동시에 처음 열어도 한 쪽만 스키마를 만든다.
    private func migrate() throws {
        let current = try userVersion()
        guard current <= Self.schemaVersion else { throw StoreError.unsupportedSchema(version: current) }
        if current == Self.schemaVersion { return }

        try exec("BEGIN IMMEDIATE")
        do {
            let version = try userVersion()
            guard version <= Self.schemaVersion else { throw StoreError.unsupportedSchema(version: version) }
            if version < 1 {
                try exec(
                    """
                    CREATE TABLE tickets (
                        id INTEGER PRIMARY KEY,
                        title TEXT NOT NULL,
                        status TEXT NOT NULL,
                        priority INTEGER,
                        project TEXT,
                        next_action TEXT,
                        note TEXT,
                        pinned_title INTEGER NOT NULL DEFAULT 0,
                        created_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL,
                        last_activity_at INTEGER NOT NULL
                    )
                    """)
                try exec(
                    """
                    CREATE TABLE locations (
                        id INTEGER PRIMARY KEY,
                        ticket_id INTEGER NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
                        kind TEXT NOT NULL,
                        locator TEXT NOT NULL,
                        source TEXT NOT NULL,
                        external_key TEXT UNIQUE,
                        last_seen_at INTEGER NOT NULL
                    )
                    """)
                try exec("CREATE INDEX idx_locations_ticket_id ON locations(ticket_id)")
                try exec("PRAGMA user_version = 1")
            }
            if version < 2 {
                try exec("ALTER TABLE tickets ADD COLUMN waiting_reason TEXT")
                try exec("ALTER TABLE tickets ADD COLUMN ended_at INTEGER")
                try exec("ALTER TABLE locations ADD COLUMN gone_at INTEGER")
                try exec("PRAGMA user_version = 2")
            }
            if version < 3 {
                try exec("ALTER TABLE locations ADD COLUMN miss_count INTEGER NOT NULL DEFAULT 0")
                try exec("PRAGMA user_version = 3")
            }
            if version < 4 {
                // 오케스트레이션 워커 세션은 티켓으로 수집하지 않는다(docs/01-product/auto-capture.md).
                try exec(
                    """
                    CREATE TABLE ignored_sessions (
                        external_key TEXT PRIMARY KEY,
                        reason TEXT,
                        created_at INTEGER
                    )
                    """)
                try exec(
                    """
                    CREATE TABLE orca_worker_handles (
                        handle TEXT PRIMARY KEY,
                        run_id TEXT,
                        seen_at INTEGER
                    )
                    """)
                try exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
                try exec("PRAGMA user_version = 4")
            }
            if version < 5 {
                // 자동 정리: 유지(kept)와 보관(archived_at). 이미 사용자가 손댄 티켓(고정 제목, next_action, note)은 유지로 시작한다.
                try exec("ALTER TABLE tickets ADD COLUMN kept INTEGER NOT NULL DEFAULT 0")
                try exec("ALTER TABLE tickets ADD COLUMN archived_at INTEGER")
                try exec(
                    "UPDATE tickets SET kept = 1 WHERE pinned_title = 1 OR next_action IS NOT NULL OR note IS NOT NULL")
                try exec("PRAGMA user_version = 5")
            }
            if version < 6 {
                // 자동 완료 표지(auto_done_at): 시스템이 done으로 만든 티켓만 같은 세션의 새 활동이 다시 연다.
                // 이미 done인 티켓은 누가 닫았는지 알 수 없으므로 표지 없이 둔다(사용자가 닫은 것으로 본다: 열지 않는 쪽이 안전하다).
                try exec("ALTER TABLE tickets ADD COLUMN auto_done_at INTEGER")
                // 사용자만 정하는 값(우선순위, blocked)이 있는 티켓은 유지로 본다. 이미 v5였던 DB에도 적용되도록 v6 단계에 둔다.
                try exec("UPDATE tickets SET kept = 1, archived_at = NULL WHERE kept = 0 AND (priority IS NOT NULL OR status = 'blocked')")
                // done은 보관 대상이 아니다: 폴러 경로로 생겼던 done+보관 조합을 푼다.
                try exec("UPDATE tickets SET archived_at = NULL WHERE status = 'done' AND archived_at IS NOT NULL")
                try exec("PRAGMA user_version = 6")
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// WAL 전환은 다른 커넥션이 막고 있으면 busy로 실패할 수 있어 잠깐씩 재시도한다.
    /// 훅이 오래 붙잡히지 않도록 총 대기 시간에 상한이 있다(시도마다 busy 대기를 짧게 하고 벽시계로 끊는다).
    private func enableWAL() throws {
        let deadline = Date().addingTimeInterval(Self.walTimeLimit)
        try exec("PRAGMA busy_timeout=250")
        defer { try? exec("PRAGMA busy_timeout=1000") }
        while true {
            do {
                try exec("PRAGMA journal_mode=WAL")
                return
            } catch StoreError.sqlite(let code, _) where [SQLITE_BUSY, SQLITE_LOCKED].contains(code & 0xFF) && Date() < deadline {
                usleep(50_000)
            }
        }
    }
    private static let walTimeLimit: TimeInterval = 1.2

    // MARK: SQLite plumbing

    private enum SQLValue {
        case int(Int64)
        case text(String)
        case null

        static func int(_ value: Int64?) -> SQLValue { value.map { .int($0) } ?? .null }
        static func text(_ value: String?) -> SQLValue { value.map { .text($0) } ?? .null }
    }

    private struct Row {
        let statement: OpaquePointer?
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func optionalInt(_ column: Int32) -> Int64? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : int(column)
        }
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
    }

    private func lastError() -> StoreError {
        .sqlite(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }

    private func exec(_ sql: String, _ params: [SQLValue] = []) throws {
        _ = try query(sql, params) { _ in () }
    }

    /// `query`와 같지만 `StoreError.corrupt`가 난 행은 경고를 남기고 건너뛴다(행 하나 때문에 목록 전체가 막히지 않게).
    private func queryLenient<T>(_ sql: String, _ params: [SQLValue], _ map: (Row) throws -> T) throws -> [T] {
        try query(sql, params) { row -> T? in
            do { return try map(row) } catch StoreError.corrupt(let detail) {
                warn("skipping \(detail)")
                return nil
            }
        }.compactMap { $0 }
    }

    private func query<T>(_ sql: String, _ params: [SQLValue], _ map: (Row) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            let bound: Int32
            switch param {
            case .int(let value): bound = sqlite3_bind_int64(statement, index, value)
            case .text(let value): bound = sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .null: bound = sqlite3_bind_null(statement, index)
            }
            guard bound == SQLITE_OK else { throw lastError() }
        }
        var results: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: results.append(try map(Row(statement: statement)))
            case SQLITE_DONE: return results
            default: throw lastError()
            }
        }
    }
}
