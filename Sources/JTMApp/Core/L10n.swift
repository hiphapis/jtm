import Foundation
import os

/// 화면에 보이는 언어. 개발(기본) 언어는 영어이고, 한국어 Mac에서는 한국어가 뜬다.
public enum AppLanguage: String, CaseIterable, Sendable {
    case en, ko

    /// 사용자의 선호 언어 목록(`Locale.preferredLanguages` 순서)에서 처음 만나는 지원 언어. 하나도 없으면 영어.
    public static func resolve(preferredLanguages: [String]) -> AppLanguage {
        for identifier in preferredLanguages {
            let code = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
            if let language = AppLanguage(rawValue: code) { return language }
        }
        return .en
    }
}

/// 화면 문구. `Resources/{en,ko}.lproj/Localizable.strings`를 `Bundle.module`에서 읽는다.
/// 시스템 로케일 규칙에 맡기지 않고 언어별 표를 직접 읽어서, 진단 도구(`--lang`)와 테스트가 언어를 정확히 고를 수 있다.
public enum L10n {
    /// 이 작업(과 그 하위 작업) 안에서만 언어를 고정한다. 테스트가 병렬로 돌아도 서로 영향을 주지 않는다.
    /// `Task.detached`와 GCD 큐로는 전해지지 않는다: 그런 곳에서 문구를 만들면 호출한 쪽에서 `current`를 넘겨야 한다.
    @TaskLocal public static var language: AppLanguage?

    private static let processOverride = OSAllocatedUnfairLock<AppLanguage?>(initialState: nil)
    private static let systemLanguage = AppLanguage.resolve(preferredLanguages: Locale.preferredLanguages)
    private static let tables = OSAllocatedUnfairLock<[AppLanguage: [String: String]]>(initialState: [:])

    /// 프로세스 전체의 언어를 고정한다(진단 도구용). nil이면 시스템 언어를 따른다.
    public static func setProcessLanguage(_ language: AppLanguage?) {
        processOverride.withLock { $0 = language }
    }

    /// 지금 쓰는 언어: 작업 단위 고정 > 프로세스 고정 > 시스템 언어.
    public static var current: AppLanguage {
        language ?? processOverride.withLock { $0 } ?? systemLanguage
    }

    /// 한 언어의 문구 표(키 → 값). 파일이 없으면 빈 표.
    public static func table(for language: AppLanguage) -> [String: String] {
        if let cached = tables.withLock({ $0[language] }) { return cached }
        let url = Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language.rawValue)
        let loaded = url.flatMap { NSDictionary(contentsOf: $0) as? [String: String] } ?? [:]
        tables.withLock { $0[language] = loaded }
        return loaded
    }

    /// 현재 언어의 문구. `%@`/`%lld` 자리에 `args`를 채운다. 번역이 빠졌으면 영어로, 그것도 없으면 키 이름을 돌려준다.
    public static func string(_ key: Key, _ args: CVarArg...) -> String {
        let language = current
        let format = table(for: language)[key.rawValue] ?? table(for: .en)[key.rawValue] ?? key.rawValue
        return args.isEmpty ? format : String(format: format, locale: Locale(identifier: language.rawValue), arguments: args)
    }
}
