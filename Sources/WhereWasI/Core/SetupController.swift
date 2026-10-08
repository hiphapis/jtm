import Foundation
import WWICore
import Observation

/// "나중에/훅 제거" 같은 선택을 기억하는 곳. 앱은 `UserDefaults`, 테스트는 메모리를 쓴다.
public protocol SetupPreferences: AnyObject, Sendable {
    /// 사용자가 메뉴에서 훅을 직접 제거했다: 그 뒤로는 카드를 먼저 띄우지 않는다(다시 설치하면 풀린다).
    var hooksRemovedByUser: Bool { get set }
}

public final class UserDefaultsSetupPreferences: SetupPreferences, @unchecked Sendable {
    private static let key = "jtm.setup.hooksRemovedByUser"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var hooksRemovedByUser: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

public final class InMemorySetupPreferences: SetupPreferences, @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init(hooksRemovedByUser: Bool = false) { value = hooksRemovedByUser }

    public var hooksRemovedByUser: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// 설정 카드가 보여 주는 Codex 신뢰 안내(요지 두 줄). CLI(`wwi hooks install`)가 찍는 `HookNotices.codexTrust`의 앞 두 줄과 같은 뜻이고,
/// CLI 문구는 한국어로 두기 때문에 앱 화면용은 언어별로 따로 둔다(한국어는 그 두 줄과 글자까지 같다).
public enum SetupNotices {
    public static var codexTrust: [String] { [L10n.string(.setupCodexTrust1), L10n.string(.setupCodexTrust2)] }
}

/// 팝오버 맨 위 "CLI와 훅 설치" 카드의 상태와 동작. 파일을 만지는 일은 `CLISetup`이 하고, 여기서는 언제 보일지와 진행 상태만 정한다.
@MainActor @Observable
public final class SetupController {
    public enum Mode: Equatable {
        /// 설치가 필요하다: 무엇을 바꾸는지 보여 주고 [설치] [나중에].
        case offer(SetupStatus)
        /// 메뉴에서 열었는데 이미 다 설치돼 있다.
        case allSet(SetupStatus)
        /// 설치/제거를 끝냈다: 결과와(Codex 훅을 썼다면) 신뢰 안내.
        case finished(SetupResult, action: Action)
    }

    public enum Action: Equatable, Sendable { case install, removeHooks }

    public private(set) var status: SetupStatus
    public private(set) var result: SetupResult?
    public private(set) var lastAction: Action = .install
    public private(set) var isWorking = false
    /// 이번 실행에서 "나중에"를 눌렀다. 다음 실행에서는 다시 묻는다.
    public private(set) var dismissed = false
    /// 푸터 메뉴 "CLI·훅 설정…"으로 열었다.
    public private(set) var forced = false

    public let setup: CLISetup
    private let preferences: SetupPreferences

    public init(setup: CLISetup, preferences: SetupPreferences) {
        self.setup = setup
        self.preferences = preferences
        self.status = setup.status()
    }

    /// 지금 카드를 그려야 하는가.
    public var mode: Mode? {
        if let result { return .finished(result, action: lastAction) }
        if forced { return status.needsSetup ? .offer(status) : .allSet(status) }
        guard status.needsSetup, !dismissed, !preferences.hooksRemovedByUser else { return nil }
        return .offer(status)
    }

    public var isVisible: Bool { mode != nil }

    /// 파일 상태를 다시 읽는다(앱을 열 때, 팝오버를 열 때). 진행 중이거나 결과를 보여 주는 동안에는 건드리지 않는다.
    public func refresh() {
        guard !isWorking, result == nil else { return }
        status = setup.status()
    }

    public func later() {
        dismissed = true
        forced = false
    }

    /// 푸터 메뉴 "CLI·훅 설정…".
    public func show() {
        guard !isWorking else { return }
        result = nil
        status = setup.status()
        forced = true
    }

    public func dismissResult() {
        result = nil
        forced = false
        status = setup.status()
    }

    public func install() async {
        await run(.install) { $0.install() }
        // 설치가 끝났으면 사용자가 직접 제거했던 기록을 지운다.
        if result?.ok == true { preferences.hooksRemovedByUser = false }
    }

    public func removeHooks() async {
        await run(.removeHooks) { $0.uninstallHooks() }
        if result?.ok == true { preferences.hooksRemovedByUser = true }
    }

    private func run(_ action: Action, _ work: @escaping @Sendable (CLISetup) -> SetupResult) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let setup = setup
        // 분리된 작업에는 작업 단위 언어 고정이 전해지지 않으므로 지금 언어를 들고 간다(결과 문구가 같은 언어로 나오게).
        let language = L10n.current
        let outcome = await Task.detached(priority: .userInitiated) { L10n.$language.withValue(language) { work(setup) } }.value
        lastAction = action
        result = outcome
        forced = false
        status = setup.status()
    }
}
