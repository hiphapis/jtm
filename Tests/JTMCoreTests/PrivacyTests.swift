import CryptoKit
import Foundation
import Testing

// 저장소에 커밋되는 테스트 데이터에 실제 이름, 경로, ID가 다시 들어오는 것을 막는다.
// 금지 목록 자체가 걸리지 않도록 이 파일에는 금지어를 그대로 적지 않는다: 문자열은 조각으로 이어 붙이고,
// 이전에 픽스처에 있던 실제 ID는 SHA-256 해시로만 둔다(UUID처럼 생긴 토큰을 해시해서 비교한다).

/// 테스트 데이터에서 걷어낸 실제 Claude/Codex 세션·프롬프트·턴 ID, Orca 탭/터미널/워크트리 ID, ChatGPT 대화/프로젝트 ID의 SHA-256(소문자).
private let removedIdentifierHashes: Set<String> = [
    "52cd75a21679a1cb08e2c3edc2020b01c9e0ae7a2b3c7ed2b637ac818a46c60f",
    "a9e9acaba74e71511690082de38fbfbec435874f3118b61b6d936cf9d15d4035",
    "ec394b44bb39439f8c2787f247caa8210059d1684547110a74eea071ab7e7202",
    "2742294ba2f82711dd4f482867e3cc9cc4340fff7d474563d41941c070b454e4",
    "e802f496da22783cb8ac8ffea9653f082d74c40f076f7d2587ce50944d37b04b",
    "545ad1ed267021491987fc8d69563f75b355c2b9a405ba49a1caaf3f5adf3649",
    "98a745904ee3ce642cc274881faf85225d96c2b6d28f932da8a47b4897cc5dc8",
    "7b61a978717876d1cb411ddfff3949b7ddb012ab52f61fde56584bcfedf97d65",
    "dbb879ad53c39e7d88620a8138418e6c60996a45259cb5ba127c42427da2e81b",
    "9708a308f7b498520e4cc9fc283766d326d3b589910b63326798ee7a66f7524c",
    "7601a6d62418338e13075ec9dac8bf51384c3a49417c722affa292d1f9651a54",
    "a799039fa289bb2ead06fab50940eff3a1bdf08e9cf8d2c49de249a9de054a5a",
    // 실제 ChatGPT 대화 ID(UUID)와 프로젝트 슬러그의 32자리 16진수 부분.
    "ab3dd140826ebf0507160de0f1911688db8ec0229be925ced39be1d76935d33f",
    "d54b8c1ce7d74e4d333e64a3aab64901d9e924c761f5ff970218705842714001",
]

private let userName = ["joh", "ankim"].joined()
private let repoName = ["joh", "an-task", "-manager"].joined()
private let orgName = ["wanted", "lab"].joined()
/// UUID, 그리고 대시 없는 32자리 16진수 토큰(ChatGPT 프로젝트 슬러그 등).
private let identifierPatterns = [
    "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", "\\b[0-9a-fA-F]{32}\\b",
]
/// 홈 디렉터리 접두사 뒤에 `me/`가 아닌 것이 오는 모든 경우.
private let foreignHomePattern = ["/Use", "rs/(?!me/)"].joined()
/// 한글 음절과 자모 범위(이스케이프로 적어서 이 파일에 한글 리터럴이 없어도 된다).
private let hangulPattern = "[\\x{AC00}-\\x{D7A3}\\x{1100}-\\x{11FF}\\x{3130}-\\x{318F}]"

private func matches(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return ["<bad pattern>"] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
}

private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// 한 파일의 위반 목록. 한글은 데이터 파일(픽스처)에서만 검사한다: Swift 소스의 주석과 한국어 메시지 단언은 정상이다.
func privacyViolations(in text: String, checksHangul: Bool) -> [String] {
    var found: [String] = []
    if text.localizedCaseInsensitiveContains(userName) { found.append("user name") }
    if text.localizedCaseInsensitiveContains(repoName) { found.append("real project name") }
    if text.localizedCaseInsensitiveContains(orgName) { found.append("organization name") }
    if !matches(foreignHomePattern, in: text).isEmpty { found.append("home directory other than /Users/me/") }
    if checksHangul, !matches(hangulPattern, in: text).isEmpty { found.append("Hangul text") }
    let tokens = Set(identifierPatterns.flatMap { matches($0, in: text) })
    for token in tokens where removedIdentifierHashes.contains(sha256(token.lowercased())) {
        found.append("removed real identifier (sha256 \(sha256(token.lowercased()).prefix(8)))")
    }
    return found
}

/// `Tests/` 아래 모든 파일(숨김 폴더 제외: `.omc/state` 같은 도구 런타임 산출물은 저장소에 없다).
private func allTestFiles() throws -> [URL] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let keys: [URLResourceKey] = [.isRegularFileKey]
    let enumerator = try #require(FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]))
    return enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true }
}

/// 저장소 루트(`Tests/JTMCoreTests/PrivacyTests.swift`의 세 단계 위).
private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// 내보내지 않는 파일: 금지 패턴 목록 자체(`publish-public.sh`가 비공개로 둔다)는 금지어를 그대로 담고 있다.
private let neverExported: Set<String> = ["scripts/public/denylist.txt"]

/// `publish-public.sh`의 `ALLOWLIST` 항목(공개 저장소로 나가는 경로). 스크립트와 어긋나지 않게 그 줄을 읽는다.
private func exportAllowlist() throws -> [String] {
    let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/publish-public.sh"), encoding: .utf8)
    let line = try #require(script.split(separator: "\n").first { $0.hasPrefix("ALLOWLIST=\"") })
    return line.dropFirst("ALLOWLIST=\"".count).dropLast().split(separator: " ").map(String.init)
}

/// 공개 저장소로 나가는 파일 중 이 테스트가 읽는 것: 허용 목록의 코드·스크립트·워크플로·문서.
/// `Tests/`는 아래의 더 엄격한 검사(한글 포함)가 맡고, `docs/images`는 이진 파일이라 뺀다.
private func shippedFiles() throws -> [URL] {
    let root = repositoryRoot()
    let keys: [URLResourceKey] = [.isRegularFileKey]
    var files: [URL] = []
    for entry in try exportAllowlist() where entry != "Tests" && entry != "docs/images" {
        let url = root.appendingPathComponent(entry)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
        if isDirectory.boolValue,
           let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            files += enumerator.compactMap { $0 as? URL }
        } else {
            files.append(url)  // 루트의 파일(Package.swift, VERSION, README.md …)
        }
    }
    return files.filter {
        (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true
            && !neverExported.contains($0.path.replacingOccurrences(of: root.path + "/", with: ""))
    }
}

@Suite struct PrivacyTests {
    /// 공개 저장소로 나가는 소스·스크립트·워크플로·문서에는 개인 이름, 조직 이름, `/Users/me/` 가 아닌 홈 경로가 없다(주석 포함).
    @Test func shippedCodeAndScriptsContainNoPersonalNamesOrPaths() throws {
        let files = try shippedFiles()
        #expect(files.count > 40, "scanned only \(files.count) files")
        #expect(files.contains { $0.lastPathComponent == "build-app.sh" })
        #expect(files.contains { $0.lastPathComponent == "publish-public.sh" })  // 내보내는 스크립트 자체는 검사한다
        #expect(files.contains { $0.lastPathComponent == "README.md" })
        #expect(!files.contains { $0.lastPathComponent == "denylist.txt" })
        var problems: [String] = []
        for file in files {
            guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
                problems.append("\(file.lastPathComponent): not valid UTF-8")
                continue
            }
            // 코드·스크립트 안의 한국어 주석과 메시지는 정상이다.
            for violation in privacyViolations(in: text, checksHangul: false) {
                problems.append("\(file.path.replacingOccurrences(of: repositoryRoot().path + "/", with: "")): \(violation)")
            }
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test func noTestFileContainsRealNamesPathsOrIdentifiers() throws {
        let files = try allTestFiles()
        #expect(files.count > 20, "scanned only \(files.count) files")
        #expect(files.contains { $0.lastPathComponent == "hook-payload-samples.jsonl" })
        var problems: [String] = []
        for file in files {
            guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
                problems.append("\(file.lastPathComponent): not valid UTF-8")
                continue
            }
            let isSwift = file.pathExtension == "swift"
            for violation in privacyViolations(in: text, checksHangul: !isSwift) {
                problems.append("\(file.lastPathComponent): \(violation)")
            }
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    /// 검사기가 실제로 걸러내는지 확인한다(아무것도 못 잡는 검사기가 통과하는 일이 없도록).
    @Test func theScannerCatchesEachKindOfLeak() {
        let leaks: [(String, Bool)] = [
            ("/Use" + "rs/" + userName + "/Work/x", false),
            ("path /Use" + "rs/someone/Work", false),
            ("/Use" + "rs/me", false),  // 뒤에 `/`가 없는 것도 `me/`가 아니다
            ("project " + repoName, false),
            ("\u{D504}\u{B86C}\u{B86C}", true),
        ]
        for (text, hangul) in leaks {
            #expect(!privacyViolations(in: text, checksHangul: hangul).isEmpty, "\(text)")
        }
        #expect(privacyViolations(in: "/Use" + "rs/me/Work/app 3f2c1a9e-0000-4000-8000-000000000000", checksHangul: true).isEmpty)
        // 한글은 소스 파일 모드에서는 허용된다.
        #expect(privacyViolations(in: "// \u{D55C}\u{AE00} \u{C8FC}\u{C11D}", checksHangul: false).isEmpty)
    }

    @Test func removedIdentifierListIsWellFormedAndHashingIsStable() {
        #expect(removedIdentifierHashes.count == 14)
        #expect(removedIdentifierHashes.allSatisfy { $0.count == 64 && $0.allSatisfy(\.isHexDigit) })
        #expect(sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
