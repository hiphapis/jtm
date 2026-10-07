import Foundation
import Testing
@testable import JTMAppCore
@testable import JTMCore

@Suite struct LocalizationCompletenessTests {
    /// 모든 키가 영어와 한국어 두 표에 다 있고 비어 있지 않다(번역 누락이 없다).
    @Test(arguments: AppLanguage.allCases) func everyKeyHasAValue(language: AppLanguage) {
        let table = L10n.table(for: language)
        #expect(table.count > 100, "\(language) table has only \(table.count) entries (resource bundle missing?)")
        for key in L10n.Key.allCases {
            #expect(!(table[key.rawValue] ?? "").isEmpty, "\(language): missing \(key.rawValue)")
        }
    }

    /// 표에 코드가 쓰지 않는 키가 남아 있지 않고, 두 언어의 키 집합이 같다.
    @Test func tablesHaveNoOrphanKeys() {
        let expected = Set(L10n.Key.allCases.map(\.rawValue))
        for language in AppLanguage.allCases {
            #expect(Set(L10n.table(for: language).keys) == expected, "\(language)")
        }
    }

    /// 같은 키는 두 언어에서 같은 자리표시자를 받는다(`%@`, `%lld`, `%d`, 순서 지정 `%1$@`). 어긋나면 서식이 깨진다.
    @Test func placeholdersAgreeAcrossLanguages() throws {
        let regex = try NSRegularExpression(pattern: #"%(?:(\d+)\$)?(@|lld|d)"#)
        func placeholders(_ text: String) -> [String] {
            var position = 0
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
                position += 1
                let range = { (index: Int) in Range(match.range(at: index), in: text).map { String(text[$0]) } }
                return "\(range(1) ?? String(position))\(range(2) ?? "")"
            }.sorted()
        }
        for key in L10n.Key.allCases {
            let en = L10n.table(for: .en)[key.rawValue] ?? ""
            let ko = L10n.table(for: .ko)[key.rawValue] ?? ""
            #expect(placeholders(en) == placeholders(ko), "\(key.rawValue): en \(en) / ko \(ko)")
        }
    }

    /// 영어 표에는 한글이 섞여 있지 않다.
    @Test func englishTableHasNoHangul() {
        for (key, value) in L10n.table(for: .en) {
            #expect(value.range(of: "[\u{AC00}-\u{D7A3}]", options: .regularExpression) == nil, "\(key): \(value)")
        }
    }

    /// 앱 코드(Core/UI/App)에는 한글 문자열 리터럴이 남아 있지 않다: 화면 문구는 모두 표를 거친다(주석은 제외).
    @Test func appSourcesContainNoHardcodedKoreanStrings() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/JTMApp")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var problems: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                var code = String(line)
                if let comment = code.range(of: #"(?<!:)//"#, options: .regularExpression) { code = String(code[..<comment.lowerBound]) }
                if code.range(of: #""[^"]*[\u{AC00}-\u{D7A3}][^"]*""#, options: .regularExpression) != nil {
                    problems.append("\(url.lastPathComponent):\(number + 1): \(line)")
                }
            }
        }
        #expect(scanned >= 15, "scanned only \(scanned) files")
        #expect(problems.isEmpty, "\(problems)")
    }
}

@Suite struct LocalizationStringTests {
    @Test(.english) func englishScreenTexts() {
        #expect(MenuSection.allCases.map(\.title) == ["Waiting for me", "In progress", "Inbox", "Blocked", "Recently done", "Archive"])
        #expect([WaitingReason.permission, .turnEnd, .stale, .error].map(\.label) == ["Permission", "Turn ended", "Stalled", "Error"])
        #expect(RowAction.allCases.map(\.label) == ["Keep", "Edit next action", "Done", "Ignore", "Restore"])
        #expect(RowAction.ignoreConfirmLabel == "Delete?")
        #expect(RowAction.keep.accessibilityValue(kept: true) == "On" && RowAction.keep.accessibilityValue(kept: false) == "Off")
        #expect(LocationKind.orcaTerminal.helpText == "Orca terminal — Click to jump to this terminal")
        #expect(WaitingReason.permission.helpText == "Waiting for input: Permission request — The agent is waiting for approval to run a tool")
        #expect(SyncOutcome.orcaUnavailable.footerNotice == "Orca not connected")
        #expect(SyncOutcome.busy.footerNotice == "Syncing…")
        #expect(HotKeyStatus.failed(label: "⌥⌘J", code: -50).problem == "Couldn't register ⌥⌘J (code -50)")
        #expect(L10n.string(.setupTitle) == "Install CLI & hooks")
        #expect(L10n.string(.setupLater) == "Later" && L10n.string(.setupInstall) == "Install")
        #expect(L10n.string(.undoIgnoredMore, "Fix login", 2) == "Ignored “Fix login” and 2 more")
        #expect(L10n.string(.setupAddHooksBullet, "Codex", "~/.codex/hooks.json") == "Add Codex hooks (jtm entries) to ~/.codex/hooks.json")
        #expect(L10n.string(.statusItemWaiting, 3) == "JTM, 3 waiting for me")
    }

    @Test(.korean) func koreanScreenTexts() {
        #expect(MenuSection.allCases.map(\.title) == ["내 입력 대기", "진행 중", "Inbox", "Blocked", "최근 완료", "보관함"])
        #expect([WaitingReason.permission, .turnEnd, .stale, .error].map(\.label) == ["권한", "턴 종료", "멈춤", "오류"])
        #expect(RowAction.allCases.map(\.label) == ["유지", "next_action 편집", "완료", "무시", "되살리기"])
        #expect(RowAction.ignoreConfirmLabel == "정말 지울까요?")
        #expect(WaitingReason.permission.helpText == "입력 대기: 권한 요청 — 에이전트가 도구 실행 허락을 기다려요")
        #expect(L10n.string(.setupTitle) == "CLI와 훅 설치")
        #expect(L10n.string(.undoIgnoredMore, "로그인 고치기", 2) == "“로그인 고치기”을(를) 무시했어요 외 2건")
        // 순서 지정 자리표시자: 한국어는 파일 → 에이전트 순으로 읽는다.
        #expect(L10n.string(.setupAddHooksBullet, "Codex", "~/.codex/hooks.json") == "~/.codex/hooks.json에 Codex 훅(jtm 항목)을 추가해요")
        #expect(L10n.string(.statusItemWaiting, 3) == "JTM, 내 입력 대기 3개")
    }

    /// 한국어 Codex 신뢰 안내는 CLI가 찍는 `HookNotices.codexTrust`의 앞 두 줄과 글자까지 같다(앱 화면은 그대로다).
    @Test(.korean) func koreanCodexNoticeMatchesTheCLINotice() {
        let cli = HookNotices.codexTrust.prefix(2).map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(SetupNotices.codexTrust == cli)
    }

    @Test(.english) func englishRowAccessibilityLabel() {
        var ticket = makeTicket(1, "Fix login", status: .waiting, reason: .permission, project: "web", next: "approve", activity: epoch, kept: true)
        ticket.waitingReason = .permission
        let row = MenuRow(listing(ticket, [makeLocation(1, ticket: 1, .orcaTerminal(.init(terminalHandle: "term_x", tabId: "t")))]))
        #expect(row.accessibilityLabel(now: epoch.addingTimeInterval(300))
            == "Fix login, Project web, Waiting for input, Permission request, Orca terminal, 5m ago, Next action: approve, Kept")
    }

    @Test func relativeTimeInBothLanguages() {
        let cases: [(elapsed: TimeInterval, en: String, ko: String)] = [
            (0, "just now", "방금"), (59, "just now", "방금"), (60, "1m ago", "1분 전"), (3_599, "59m ago", "59분 전"),
            (3_600, "1h ago", "1시간 전"), (86_399, "23h ago", "23시간 전"), (86_400, "1d ago", "1일 전"), (864_000, "10d ago", "10일 전"),
            (-30, "just now", "방금"),
        ]
        for (elapsed, en, ko) in cases {
            let date = epoch.addingTimeInterval(-elapsed)
            L10n.$language.withValue(.en) { #expect(AppRelativeTime.string(from: date, now: epoch) == en) }
            L10n.$language.withValue(.ko) { #expect(AppRelativeTime.string(from: date, now: epoch) == ko) }
        }
    }

    /// 영어 상대 시간은 CLI(`JTMCore.RelativeTime`)와 같은 모양이다.
    @Test(.english) func englishRelativeTimeMatchesTheCLIFormat() {
        for elapsed: TimeInterval in [0, 59, 60, 3_599, 3_600, 86_399, 86_400, 864_000] {
            let date = epoch.addingTimeInterval(-elapsed)
            #expect(AppRelativeTime.string(from: date, now: epoch) == RelativeTime.string(from: date, now: epoch))
        }
    }

    @Test func systemLanguageFollowsThePreferredLanguageList() {
        #expect(AppLanguage.resolve(preferredLanguages: ["ko-KR", "en-US"]) == .ko)
        #expect(AppLanguage.resolve(preferredLanguages: ["en-KR", "ko-KR"]) == .en)
        #expect(AppLanguage.resolve(preferredLanguages: ["ja-JP", "ko-KR"]) == .ko)  // 지원하지 않는 언어는 건너뛴다
        #expect(AppLanguage.resolve(preferredLanguages: ["ko_KR"]) == .ko)
        #expect(AppLanguage.resolve(preferredLanguages: ["zh-Hans-CN", "fr"]) == .en)  // 하나도 없으면 영어
        #expect(AppLanguage.resolve(preferredLanguages: []) == .en)
    }

    @Test func aTaskScopedLanguageWinsAndNests() {
        L10n.$language.withValue(.ko) {
            #expect(L10n.current == .ko)
            L10n.$language.withValue(.en) { #expect(L10n.current == .en) }
            #expect(L10n.current == .ko)
        }
    }
}
