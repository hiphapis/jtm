import Foundation
import Testing
@testable import WWIAppCore

/// 테스트마다 따로 만든 `UserDefaults` 스위트. 진짜 사용자 설정(`.standard`)은 건드리지 않는다.
private func withScratchDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
    let name = "wwi-language-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    return try body(defaults)
}

@Suite struct LanguageResolutionTests {
    /// 고른 언어가 있으면 macOS 설정보다 앞서고, 없으면 macOS 설정을 따른다.
    @Test func overrideBeatsTheSystemLanguage() {
        #expect(AppLanguage.resolve(override: .en, preferredLanguages: ["ko-KR"]) == .en)
        #expect(AppLanguage.resolve(override: .ko, preferredLanguages: ["en-US"]) == .ko)
        #expect(AppLanguage.resolve(override: .ko, preferredLanguages: []) == .ko)
        #expect(AppLanguage.resolve(override: nil, preferredLanguages: ["ko-KR"]) == .ko)
        #expect(AppLanguage.resolve(override: nil, preferredLanguages: ["fr-FR"]) == .en)
    }

    @Test func choicesMapToLanguages() {
        #expect(LanguageChoice.allCases == [.system, .en, .ko])
        #expect(LanguageChoice.allCases.map(\.language) == [nil, .en, .ko])
        #expect(LanguageChoice.allCases.map(\.rawValue) == ["system", "en", "ko"])
    }

    /// 언어 이름은 그 언어 자신의 글자로, 하위 메뉴 제목은 어느 언어에서나 같다.
    @Test(arguments: AppLanguage.allCases) func menuTitlesAreStableAcrossLanguages(language: AppLanguage) {
        L10n.$language.withValue(language) {
            #expect(LanguageChoice.menuTitle == "Language / 언어")
            #expect(LanguageChoice.en.title == "English")
            #expect(LanguageChoice.ko.title == "한국어")
        }
    }

    @Test func systemChoiceTitleFollowsTheScreenLanguage() {
        L10n.$language.withValue(.en) { #expect(LanguageChoice.system.title == "System (follows macOS)") }
        L10n.$language.withValue(.ko) { #expect(LanguageChoice.system.title == "시스템 설정 따름") }
    }
}

@Suite(.serialized) @MainActor struct LanguagePreferenceTests {
    /// 프로세스 고정(`--lang`)과 작업 단위 고정은 사용자가 고른 언어보다 앞선다. 프로세스 전체 상태를 바꾸므로 이 직렬 스위트 안에 둔다.
    @Test func diagnosticPinsWinOverTheStoredChoice() {
        L10n.setStoredLanguage(.ko)
        defer { L10n.setStoredLanguage(nil) }
        L10n.$language.withValue(.en) { #expect(L10n.current == .en) }
        L10n.setProcessLanguage(.en)
        defer { L10n.setProcessLanguage(nil) }
        #expect(L10n.current == .en)
    }

    @Test func parsesTheStoredValue() {
        withScratchDefaults { defaults in
            #expect(LanguagePreference.stored(in: defaults) == .system)  // 아무것도 없으면 시스템
            for choice in LanguageChoice.allCases {
                defaults.set(choice.rawValue, forKey: LanguagePreference.defaultsKey)
                #expect(LanguagePreference.stored(in: defaults) == choice)
            }
            defaults.set("fr", forKey: LanguagePreference.defaultsKey)  // 알 수 없는 값
            #expect(LanguagePreference.stored(in: defaults) == .system)
            defaults.set(7, forKey: LanguagePreference.defaultsKey)  // 문자열이 아닌 값
            #expect(LanguagePreference.stored(in: defaults) == .system)
        }
    }

    @Test func persistsUnderTheDocumentedKey() {
        withScratchDefaults { defaults in
            let preference = LanguagePreference(defaults: defaults, apply: { _ in })
            #expect(preference.choice == .system)
            #expect(LanguagePreference.defaultsKey == "jtm.language")
            preference.select(.ko)
            #expect(defaults.string(forKey: "jtm.language") == "ko")
            preference.select(.en)
            #expect(defaults.string(forKey: "jtm.language") == "en")
            preference.select(.system)
            #expect(defaults.string(forKey: "jtm.language") == nil)  // 기본값으로 돌아가면 키를 지운다
            #expect(preference.choice == .system)
        }
    }

    @Test func aNewInstanceReadsWhatWasSavedAndAppliesItAtOnce() {
        withScratchDefaults { defaults in
            LanguagePreference(defaults: defaults, apply: { _ in }).select(.ko)
            var applied: [AppLanguage?] = []
            let preference = LanguagePreference(defaults: defaults, apply: { applied.append($0) })
            #expect(preference.choice == .ko)
            #expect(applied == [.ko])
        }
    }

    @Test func selectingTheCurrentChoiceDoesNothing() {
        withScratchDefaults { defaults in
            var applied: [AppLanguage?] = []
            let preference = LanguagePreference(defaults: defaults, apply: { applied.append($0) })
            applied.removeAll()
            preference.select(.system)
            #expect(applied.isEmpty)
            preference.select(.en)
            preference.select(.en)
            #expect(applied == [.en])
        }
    }

    @Test func theChoiceIsObservable() {
        withScratchDefaults { defaults in
            let preference = LanguagePreference(defaults: defaults, apply: { _ in })
            let changed = ChangeFlag()
            withObservationTracking { _ = preference.choice } onChange: { changed.set() }
            preference.select(.ko)
            #expect(changed.value)
        }
    }

    /// 고르는 즉시 모델이 내놓는 문구가 바뀐다. 전역 `L10n`을 건드리므로 끝에 되돌린다(작업 단위 고정을 쓰는 다른 테스트는 영향이 없다).
    @Test func switchingChangesTheStringsTheModelExposes() {
        withScratchDefaults { defaults in
            L10n.$language.withValue(nil) {
                defer { L10n.setStoredLanguage(nil) }
                let preference = LanguagePreference(defaults: defaults)  // 기본 적용 대상: L10n
                preference.select(.en)
                #expect(MenuSection.allCases.map(\.title).first == "Waiting for me")
                #expect(RowAction.ignoreConfirmLabel == "Delete?")
                #expect(L10n.string(.statusItemWaiting, 3) == "Where Was I, 3 waiting for me")
                #expect(AppRelativeTime.string(from: epoch.addingTimeInterval(-300), now: epoch) == "5m ago")
                preference.select(.ko)
                #expect(MenuSection.allCases.map(\.title).first == "내 입력 대기")
                #expect(RowAction.ignoreConfirmLabel == "정말 지울까요?")
                #expect(L10n.string(.statusItemWaiting, 3) == "Where Was I, 내 입력 대기 3개")
                #expect(AppRelativeTime.string(from: epoch.addingTimeInterval(-300), now: epoch) == "5분 전")
                preference.select(.system)
                #expect(L10n.current == AppLanguage.resolve(preferredLanguages: Locale.preferredLanguages))
            }
        }
    }
}

private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
