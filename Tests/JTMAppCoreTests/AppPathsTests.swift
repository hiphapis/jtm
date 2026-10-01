import Testing
@testable import JTMAppCore

@Suite struct AppPathsTests {
    @Test func usesTheSameDatabasePathRuleAsTheCLI() {
        #expect(AppPaths.databasePath(environment: ["JTM_DB_PATH": "/tmp/x.sqlite"], home: "/Users/me/home") == "/tmp/x.sqlite")
        #expect(AppPaths.databasePath(environment: [:], home: "/Users/me/home") == "/Users/me/home/Library/Application Support/jtm/jtm.sqlite")
        #expect(AppPaths.databasePath(environment: ["JTM_DB_PATH": ""], home: "/Users/me/home") == "/Users/me/home/Library/Application Support/jtm/jtm.sqlite")
    }
}
