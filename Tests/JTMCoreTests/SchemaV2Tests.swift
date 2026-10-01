import Foundation
import SQLite3
import Testing
@testable import JTMCore

@Suite struct SchemaV2Tests {
    /// Phase 1이 만든 v1 스키마(그대로)와 데이터.
    private func makeV1Database(at path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var db: OpaquePointer?
        precondition(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE tickets (id INTEGER PRIMARY KEY, title TEXT NOT NULL, status TEXT NOT NULL, priority INTEGER,
                project TEXT, next_action TEXT, note TEXT, pinned_title INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, last_activity_at INTEGER NOT NULL);
            CREATE TABLE locations (id INTEGER PRIMARY KEY, ticket_id INTEGER NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
                kind TEXT NOT NULL, locator TEXT NOT NULL, source TEXT NOT NULL, external_key TEXT UNIQUE, last_seen_at INTEGER NOT NULL);
            CREATE INDEX idx_locations_ticket_id ON locations(ticket_id);
            INSERT INTO tickets VALUES (1, 'old', 'waiting', NULL, NULL, NULL, NULL, 0, 100, 100, 100);
            INSERT INTO locations VALUES (1, 1, 'codex_thread', '{"threadId":"t-1"}', 'hook', 'codex:t-1', 100);
            PRAGMA user_version = 1;
            """
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func v1DatabaseMigratesToTheLatestSchemaKeepingRows() throws {
        let path = NSTemporaryDirectory() + "jtm-tests-\(UUID().uuidString)/jtm.sqlite"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try makeV1Database(at: path)

        let store = try Store(path: path)
        #expect(rawSQL(path, "PRAGMA user_version") { sqlite3_column_int($0, 0) } == 6)
        let ticket = try store.getTicket(id: 1)
        #expect(ticket.title == "old" && ticket.status == .waiting)
        #expect(ticket.waitingReason == nil && ticket.endedAt == nil)
        let location = try #require(try store.locations(ticketId: 1).first)
        #expect(location.goneAt == nil && location.missCount == 0)
        #expect(location.locator == .codexThread(.init(threadId: "t-1")))
    }

    /// v2(Phase 2 초기)에서 v3으로: `miss_count` 열이 0으로 더해지고 기존 행과 gone_at은 그대로다.
    @Test func v2DatabaseGainsMissCountWithoutLosingRows() throws {
        let path = NSTemporaryDirectory() + "jtm-tests-\(UUID().uuidString)/jtm.sqlite"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try makeV1Database(at: path)
        var db: OpaquePointer?
        precondition(sqlite3_open(path, &db) == SQLITE_OK)
        let sql = """
            ALTER TABLE tickets ADD COLUMN waiting_reason TEXT;
            ALTER TABLE tickets ADD COLUMN ended_at INTEGER;
            ALTER TABLE locations ADD COLUMN gone_at INTEGER;
            UPDATE locations SET gone_at = 150;
            PRAGMA user_version = 2;
            """
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = try Store(path: path)
        #expect(rawSQL(path, "PRAGMA user_version") { sqlite3_column_int($0, 0) } == 6)
        let location = try #require(try store.locations(ticketId: 1).first)
        #expect(location.missCount == 0 && location.goneAt == Date(timeIntervalSince1970: 150))
        #expect(try store.recordLocationMiss(id: location.id) == 1)
        #expect(try store.recordLocationMiss(id: location.id) == 2)
        // 훅/폴러가 다시 보면 upsert가 카운터를 지운다.
        try store.upsertLocation(
            byExternalKey: "codex:t-1", ticketId: 1, locator: .codexThread(.init(threadId: "t-1")), source: .hook)
        #expect(try store.location(byExternalKey: "codex:t-1")?.missCount == 0)
    }

    /// v3(Phase 3까지)에서 v4로: 무시할 세션, 워커 handle, meta 테이블이 생기고 기존 행은 그대로다.
    @Test func v3DatabaseGainsTheWorkerTablesWithoutLosingRows() throws {
        let path = NSTemporaryDirectory() + "jtm-tests-\(UUID().uuidString)/jtm.sqlite"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try makeV1Database(at: path)
        var db: OpaquePointer?
        precondition(sqlite3_open(path, &db) == SQLITE_OK)
        let sql = """
            ALTER TABLE tickets ADD COLUMN waiting_reason TEXT;
            ALTER TABLE tickets ADD COLUMN ended_at INTEGER;
            ALTER TABLE locations ADD COLUMN gone_at INTEGER;
            ALTER TABLE locations ADD COLUMN miss_count INTEGER NOT NULL DEFAULT 0;
            PRAGMA user_version = 3;
            """
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = try Store(path: path)
        #expect(rawSQL(path, "PRAGMA user_version") { sqlite3_column_int($0, 0) } == 6)
        #expect(try store.getTicket(id: 1).title == "old")
        #expect(try store.isSessionIgnored("claude:x") == false && store.orcaWorkerHandles().isEmpty && store.meta("k") == nil)
        try store.ignoreSession("claude:x", reason: "r")
        #expect(try store.isSessionIgnored("claude:x"))
        // 다시 열어도 그대로다(마이그레이션은 한 번만).
        #expect(try Store(path: path).isSessionIgnored("claude:x"))
    }

    /// v4(오케스트레이션 워커 무시까지)에서 v5로: `kept`, `archived_at`이 생기고, 이미 손댄 티켓(고정 제목, next_action, note)만 유지로 시작한다.
    @Test func v4DatabaseGainsKeptAndArchivedAtAndKeepsTouchedTickets() throws {
        let path = NSTemporaryDirectory() + "jtm-tests-\(UUID().uuidString)/jtm.sqlite"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try makeV1Database(at: path)
        var db: OpaquePointer?
        precondition(sqlite3_open(path, &db) == SQLITE_OK)
        let sql = """
            ALTER TABLE tickets ADD COLUMN waiting_reason TEXT;
            ALTER TABLE tickets ADD COLUMN ended_at INTEGER;
            ALTER TABLE locations ADD COLUMN gone_at INTEGER;
            ALTER TABLE locations ADD COLUMN miss_count INTEGER NOT NULL DEFAULT 0;
            CREATE TABLE ignored_sessions (external_key TEXT PRIMARY KEY, reason TEXT, created_at INTEGER);
            CREATE TABLE orca_worker_handles (handle TEXT PRIMARY KEY, run_id TEXT, seen_at INTEGER);
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO tickets (id, title, status, pinned_title, next_action, note, created_at, updated_at, last_activity_at)
                VALUES (2, 'pinned', 'active', 1, NULL, NULL, 100, 100, 100),
                       (3, 'next', 'active', 0, 'do it', NULL, 100, 100, 100),
                       (4, 'note', 'waiting', 0, NULL, 'remember', 100, 100, 100),
                       (5, 'plain', 'inbox', 0, NULL, NULL, 100, 100, 100),
                       (6, 'priority only', 'active', 0, NULL, NULL, 100, 100, 100),
                       (7, 'blocked', 'blocked', 0, NULL, NULL, 100, 100, 100);
            UPDATE tickets SET priority = 1 WHERE id = 6;
            PRAGMA user_version = 4;
            """
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = try Store(path: path)
        #expect(rawSQL(path, "PRAGMA user_version") { sqlite3_column_int($0, 0) } == 6)
        let kept = try store.listTickets().sorted { $0.id < $1.id }.map { "\($0.id):\($0.kept)" }
        // v6 단계: 우선순위를 준 티켓과 blocked(사용자만 정하는 상태)도 유지다.
        #expect(kept == ["1:false", "2:true", "3:true", "4:true", "5:false", "6:true", "7:true"])
        #expect(try store.listTickets().allSatisfy { $0.archivedAt == nil && $0.autoDoneAt == nil })
        // 다시 열어도 그대로고(마이그레이션은 한 번만), 읽기 전용 연결도 열린다.
        _ = try Store(path: path)
        #expect(try Store(readOnlyPath: path).listTickets().count == 7)
    }

    /// 이미 v5였던 DB에서 v6으로: `auto_done_at`이 생기고, 사용자만 정하는 값이 있던 티켓은 유지가 되며 보관이 풀리고,
    /// 폴러 경로로 생긴 done+보관 조합도 풀린다. 이미 done인 티켓에는 표지가 없다(사용자가 닫은 것으로 본다).
    @Test func v5DatabaseGainsAutoDoneAtAndRepairsUserOnlyValuesAndDoneArchives() throws {
        let path = NSTemporaryDirectory() + "jtm-tests-\(UUID().uuidString)/jtm.sqlite"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try makeV1Database(at: path)
        var db: OpaquePointer?
        precondition(sqlite3_open(path, &db) == SQLITE_OK)
        let sql = """
            ALTER TABLE tickets ADD COLUMN waiting_reason TEXT;
            ALTER TABLE tickets ADD COLUMN ended_at INTEGER;
            ALTER TABLE locations ADD COLUMN gone_at INTEGER;
            ALTER TABLE locations ADD COLUMN miss_count INTEGER NOT NULL DEFAULT 0;
            CREATE TABLE ignored_sessions (external_key TEXT PRIMARY KEY, reason TEXT, created_at INTEGER);
            CREATE TABLE orca_worker_handles (handle TEXT PRIMARY KEY, run_id TEXT, seen_at INTEGER);
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            ALTER TABLE tickets ADD COLUMN kept INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE tickets ADD COLUMN archived_at INTEGER;
            INSERT INTO tickets (id, title, status, priority, created_at, updated_at, last_activity_at, archived_at)
                VALUES (2, 'blocked archived', 'blocked', NULL, 100, 100, 100, 150),
                       (3, 'priority archived', 'waiting', 2, 100, 100, 100, 150),
                       (4, 'done archived', 'done', NULL, 100, 100, 100, 150),
                       (5, 'plain archived', 'inbox', NULL, 100, 100, 100, 150);
            PRAGMA user_version = 5;
            """
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = try Store(path: path)
        #expect(rawSQL(path, "PRAGMA user_version") { sqlite3_column_int($0, 0) } == 6)
        let byId = Dictionary(uniqueKeysWithValues: try store.listTickets().map { ($0.id, $0) })
        #expect(byId[2]?.kept == true && byId[2]?.archivedAt == nil)
        #expect(byId[3]?.kept == true && byId[3]?.archivedAt == nil)
        #expect(byId[4]?.status == .done && byId[4]?.archivedAt == nil && byId[4]?.autoDoneAt == nil)
        #expect(byId[5]?.kept == false && byId[5]?.archivedAt != nil)  // 일반 보관 티켓은 그대로
        #expect(rawSQL(path, "PRAGMA integrity_check") { String(cString: sqlite3_column_text($0, 0)) } == "ok")
    }

    @Test func freshAndMigratedDatabasesHaveTheSameColumns() throws {
        let migrated = NSTemporaryDirectory() + "jtm-tests-\(UUID().uuidString)/jtm.sqlite"
        defer { try? FileManager.default.removeItem(atPath: (migrated as NSString).deletingLastPathComponent) }
        try makeV1Database(at: migrated)
        _ = try Store(path: migrated)

        try withStore { _, _, fresh in
            for table in ["tickets", "locations", "ignored_sessions", "orca_worker_handles", "meta"] {
                func columns(_ path: String) -> [String] {
                    var db: OpaquePointer?
                    sqlite3_open(path, &db)
                    defer { sqlite3_close(db) }
                    var statement: OpaquePointer?
                    sqlite3_prepare_v2(db, "SELECT name FROM pragma_table_info('\(table)') ORDER BY cid", -1, &statement, nil)
                    defer { sqlite3_finalize(statement) }
                    var names: [String] = []
                    while sqlite3_step(statement) == SQLITE_ROW { names.append(String(cString: sqlite3_column_text(statement, 0))) }
                    return names
                }
                #expect(columns(fresh) == columns(migrated), "\(table)")
            }
        }
    }

    @Test func newColumnsRoundTripThroughThePatchAPI() throws {
        try withStore { store, clock, _ in
            let ticket = try store.createTicket(title: "t", status: .active)
            let waiting = try store.patchTicket(id: ticket.id, TicketPatch(status: .waiting, waitingReason: .some(.permission)))
            #expect(waiting.status == .waiting && waiting.waitingReason == .permission)

            let ended = try store.patchTicket(id: ticket.id, TicketPatch(endedAt: .some(clock.current)))
            #expect(ended.endedAt == clock.current && ended.waitingReason == .permission)  // 상태를 안 바꾸면 이유는 그대로

            // 상태를 바꾸면서 이유를 안 주면 이전 이유는 지워진다.
            let done = try store.patchTicket(id: ticket.id, TicketPatch(status: .done))
            #expect(done.waitingReason == nil)

            let cleared = try store.patchTicket(id: ticket.id, TicketPatch(endedAt: .some(nil)))
            #expect(cleared.endedAt == nil)
        }
    }

    @Test func createTicketStoresWaitingReason() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(NewTicket(title: "t", status: .waiting, waitingReason: .turnEnd))
            #expect(ticket.waitingReason == .turnEnd)
        }
    }

    @Test func moveLocationReassignsTheTicketAndKeepsTheRest() throws {
        try withStore { store, clock, _ in
            let a = try store.createTicket(title: "a"), b = try store.createTicket(title: "b")
            let tab = try store.addLocation(
                ticketId: a.id, locator: .orcaTerminal(.init(terminalHandle: "term_1", tabId: "T")),
                source: .hook, externalKey: "orca-tab:T")
            clock.advance(60)
            let moved = try store.moveLocation(id: tab.id, toTicketId: b.id)
            #expect(moved.ticketId == b.id && moved.locator == tab.locator && moved.lastSeenAt == tab.lastSeenAt)
            #expect(try store.locations(ticketId: a.id).isEmpty)
            #expect(try store.locations(ticketId: b.id).map(\.id) == [tab.id])
        }
    }

    @Test func moveLocationRejectsUnknownTicketOrLocation() throws {
        try withStore { store, _, _ in
            let a = try store.createTicket(title: "a")
            let loc = try store.addLocation(ticketId: a.id, locator: .url(.init(url: "https://x.example")), source: .manual)
            #expect(throws: StoreError.self) { try store.moveLocation(id: loc.id, toTicketId: 999) }
            #expect(throws: StoreError.self) { try store.moveLocation(id: 999, toTicketId: a.id) }
            #expect(try store.locations(ticketId: a.id).map(\.id) == [loc.id])
        }
    }

    @Test func goneAtIsMarkedAndClearedWhenTheLocationIsSeenAgain() throws {
        try withStore { store, clock, _ in
            let ticket = try store.createTicket(title: "t")
            let key = "orca-tab:T"
            let locator = Locator.orcaTerminal(.init(terminalHandle: "term_1", tabId: "T"))
            let loc = try store.addLocation(ticketId: ticket.id, locator: locator, source: .hook, externalKey: key)
            let gone = try store.setLocationGone(id: loc.id, at: clock.current)
            #expect(gone.goneAt == clock.current)
            #expect(try store.getTicket(id: ticket.id).status == ticket.status)
            let seen = try store.upsertLocation(byExternalKey: key, ticketId: ticket.id, locator: locator, source: .hook)
            #expect(seen.goneAt == nil)
        }
    }

    @Test func jsonEncodesNewFieldsAsExplicitNulls() throws {
        try withStore { store, _, _ in
            let ticket = try store.createTicket(title: "t")
            let location = try store.addLocation(ticketId: ticket.id, locator: .url(.init(url: "https://x.example")), source: .manual)
            let ticketJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ticket)) as? [String: Any])
            #expect(ticketJSON["waitingReason"] is NSNull && ticketJSON["endedAt"] is NSNull)
            let locationJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(location)) as? [String: Any])
            #expect(locationJSON["goneAt"] is NSNull)
        }
    }

    @Test func codexLocatorCwdIsOptionalAndOmittedWhenNil() throws {
        let plain = Locator.codexThread(.init(threadId: "t"))
        #expect(String(decoding: try plain.jsonData(), as: UTF8.self) == #"{"threadId":"t"}"#)
        let withCwd = Locator.codexThread(.init(threadId: "t", cwd: "/w"))
        #expect(String(decoding: try withCwd.jsonData(), as: UTF8.self) == #"{"cwd":"\/w","threadId":"t"}"#)
        let old = try Locator(kind: .codexThread, json: Data(#"{"threadId":"t"}"#.utf8))
        #expect(old == plain)
    }
}
