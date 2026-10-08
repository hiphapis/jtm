import Foundation
import Observation

/// 푸터 "…" 메뉴의 언어 선택지.
public enum LanguageChoice: String, CaseIterable, Sendable {
    /// macOS 언어 설정을 따른다(기본).
    case system
    case en, ko

    /// 고정할 언어. 시스템을 따르면 nil.
    public var language: AppLanguage? {
        switch self {
        case .system: nil
        case .en: .en
        case .ko: .ko
        }
    }

    /// 하위 메뉴 제목. 지금 어떤 언어로 보이든 같다: 엉뚱한 언어로 바뀐 사용자도 이 메뉴를 찾을 수 있게 두 언어를 같이 쓴다.
    /// (한글은 표 밖 코드에 리터럴로 둘 수 없어서 유니코드 이스케이프로 쓴다: 앱 소스에 한글 문자열 리터럴이 없다는 테스트가 있다.)
    public static let menuTitle = "Language / \u{C5B8}\u{C5B4}"

    /// 메뉴에 보이는 이름. 언어 이름은 그 언어 자신의 글자로 쓰고, "시스템" 항목만 화면 언어를 따른다.
    public var title: String {
        switch self {
        case .system: L10n.string(.languageSystem)
        case .en: "English"
        case .ko: "\u{D55C}\u{AD6D}\u{C5B4}"  // 한국어
        }
    }
}

/// 사용자가 고른 화면 언어. `UserDefaults`(앱 도메인)에 `jtm.language`로 `system|en|ko`를 저장하고,
/// 고르는 즉시 `L10n`에 반영한 뒤 관찰자(뷰, 상태 아이템)에게 알린다.
@MainActor @Observable
public final class LanguagePreference {
    public nonisolated static let defaultsKey = "jtm.language"

    /// 저장된 값을 읽는다. 없거나 알 수 없는 값이면 시스템을 따른다.
    public nonisolated static func stored(in defaults: UserDefaults) -> LanguageChoice {
        defaults.string(forKey: defaultsKey).flatMap(LanguageChoice.init(rawValue:)) ?? .system
    }

    public private(set) var choice: LanguageChoice

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let apply: @MainActor (AppLanguage?) -> Void

    /// `defaults`는 테스트가 따로 만든 스위트를 넣을 수 있게 열어 두었다. `apply`는 기본이 `L10n`(프로세스 전체)이다.
    /// 만들면서 저장된 선택을 바로 적용한다.
    public init(defaults: UserDefaults = .standard, apply: @escaping @MainActor (AppLanguage?) -> Void = { L10n.setStoredLanguage($0) }) {
        self.defaults = defaults
        self.apply = apply
        let stored = Self.stored(in: defaults)
        choice = stored
        apply(stored.language)
    }

    /// 선택을 저장하고 즉시 적용한다. `L10n`을 먼저 바꾼 뒤 `choice`를 바꾸므로, 관찰자가 깨어날 때는 이미 새 언어다.
    public func select(_ choice: LanguageChoice) {
        guard choice != self.choice else { return }
        if choice == .system { defaults.removeObject(forKey: Self.defaultsKey) } else { defaults.set(choice.rawValue, forKey: Self.defaultsKey) }
        apply(choice.language)
        self.choice = choice
    }
}
