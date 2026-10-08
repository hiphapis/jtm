import Testing
@testable import WWIAppCore

@Suite struct AppPathsTests {
    @Test func usesTheSameDatabasePathRuleAsTheCLI() {
        #expect(AppPaths.databasePath(environment: ["WWI_DB_PATH": "/tmp/x.sqlite"], home: "/Users/me/home") == "/tmp/x.sqlite")
        #expect(AppPaths.databasePath(environment: [:], home: "/Users/me/home") == "/Users/me/home/Library/Application Support/jtm/jtm.sqlite")
        #expect(AppPaths.databasePath(environment: ["WWI_DB_PATH": ""], home: "/Users/me/home") == "/Users/me/home/Library/Application Support/jtm/jtm.sqlite")
    }

    // 훅은 사용자의 환경을 그대로 이어받는다: 예전 이름의 JTM_DB_PATH를 쓰던 사람의 DB 위치가 바뀌면 안 된다.
    @Test func fallsBackToTheLegacyJTMDatabaseVariable() {
        #expect(AppPaths.databasePath(environment: ["JTM_DB_PATH": "/tmp/old.sqlite"], home: "/Users/me/home") == "/tmp/old.sqlite")
        #expect(AppPaths.databasePath(environment: ["WWI_DB_PATH": "/tmp/new.sqlite", "JTM_DB_PATH": "/tmp/old.sqlite"], home: "/Users/me/home") == "/tmp/new.sqlite")
        #expect(AppPaths.databasePath(environment: ["WWI_DB_PATH": "", "JTM_DB_PATH": "/tmp/old.sqlite"], home: "/Users/me/home") == "/tmp/old.sqlite")
        #expect(AppPaths.databasePath(environment: ["JTM_DB_PATH": ""], home: "/Users/me/home") == "/Users/me/home/Library/Application Support/jtm/jtm.sqlite")
    }
}
