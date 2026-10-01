import Foundation
import Testing
@testable import JTMAppCore

private func repositoryFile(_ name: String) -> String? {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
}

@Suite struct AppIdentityTests {
    @Test func bundleIdentifierIsTheOpenSourceOne() {
        #expect(AppIdentity.bundleIdentifier == "io.github.hiphapis.jtm")
    }

    /// 빌드 스크립트의 기본 번들 ID가 코드의 상수와 어긋나면 로그 subsystem과 앱 식별이 갈라진다.
    @Test func buildScriptDefaultsToTheSameBundleIdentifier() throws {
        let script = try #require(repositoryFile("scripts/build-app.sh"))
        #expect(script.contains("BUNDLE_ID=\"${JTM_BUNDLE_ID:-\(AppIdentity.bundleIdentifier)}\""))
    }

    @Test func versionFileHoldsAPlainSemanticVersion() throws {
        let version = try #require(repositoryFile("VERSION")).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(version.range(of: #"^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$"#, options: .regularExpression) != nil, "\(version)")
    }
}
