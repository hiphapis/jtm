import WWIAppCore
import Observation

/// 팝오버/패널 본문이 앱 셸에 부탁하는 것들: 자동 실행 설정, 닫기, 종료. 뷰는 이것만 알고 AppKit 창은 모른다.
@MainActor @Observable
public final class MenuHost {
    public let controller: MenuController
    /// 첫 실행 설정 카드(CLI 링크 + 훅). nil이면 이 호스트는 설정을 다루지 않는다.
    public let setup: SetupController?
    /// 화면 언어 선택(푸터 메뉴). nil이면 이 호스트는 언어를 바꿀 수 없다(진단 도구).
    public let language: LanguagePreference?
    public var launchAtLogin = false
    public var launchAtLoginError: String?
    /// nil이면 아직 등록 전.
    public var hotKeyStatus: HotKeyStatus?
    /// 메뉴바 아이콘이 숨겨져 있다(사용자가 치웠거나 시스템 설정에서 껐다): 팝오버 대신 앵커 없는 패널이 뜨고 푸터가 안내한다.
    public var iconHidden = false

    @ObservationIgnored public var onSetLaunchAtLogin: @MainActor (Bool) -> Void = { _ in }
    @ObservationIgnored public var onClose: @MainActor () -> Void = {}
    @ObservationIgnored public var onQuit: @MainActor () -> Void = {}

    public init(controller: MenuController, setup: SetupController? = nil, language: LanguagePreference? = nil) {
        self.controller = controller
        self.setup = setup
        self.language = language
    }

    public func setLaunchAtLogin(_ enabled: Bool) { onSetLaunchAtLogin(enabled) }
    public func close() { onClose() }
    public func quit() { onQuit() }
}
