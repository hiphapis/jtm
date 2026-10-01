import Foundation
import SQLite3
@testable import JTMCore

/// 테스트마다 고유한 임시 DB 경로를 쓴다(병렬 실행 안전, 전역 env 미사용). 끝나면 디렉터리를 지운다.
final class TestClock {
    var current = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

@discardableResult
func withStore<T>(_ body: (Store, TestClock, String) throws -> T) throws -> T {
    let directory = NSTemporaryDirectory() + "jtm-tests-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let path = directory + "/nested/jtm.sqlite"
    let clock = TestClock()
    let store = try Store(path: path, now: { clock.current })
    return try body(store, clock, path)
}

/// Store를 거치지 않고 같은 DB 파일을 직접 조회/조작한다(스키마 검증용).
func rawSQL<T>(_ path: String, _ sql: String, foreignKeys: Bool = false, _ read: (OpaquePointer?) -> T) -> T {
    var db: OpaquePointer?
    precondition(sqlite3_open(path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    if foreignKeys { sqlite3_exec(db, "PRAGMA foreign_keys=ON", nil, nil, nil) }
    var statement: OpaquePointer?
    precondition(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    _ = sqlite3_step(statement)
    return read(statement)
}
