import AppKit
import JTMAppCore
import JTMAppUI
import JTMCore
import ServiceManagement

/// 앱 전체에서 하나뿐인 런타임: 컨트롤러, 상태 아이템/팝오버/패널, 전역 단축키, 로그인 시 실행 설정.
@MainActor
final class AppRuntime {
    static let shared = AppRuntime()

    let controller: MenuController
    let host: MenuHost
    let databasePath: String
    private var presenter: StatusItemController?
    private var hotKey: GlobalHotKey?

    private init() {
        // 컨트롤러와 뷰를 만들기 전에 저장된 언어를 L10n에 올린다.
        let language = LanguagePreference()
        databasePath = AppPaths.databasePath()
        // Orca가 설치돼 있지 않은 Mac에서는 동기화를 조용히 건너뛴다(푸터에 "Orca 연결 안 됨"도 띄우지 않는다).
        let worker = SyncWorker(
            databasePath: databasePath, fetchWorkers: SyncWorker.liveFetchWorkers,
            isOrcaInstalled: { OrcaCLI.locate() != nil })
        controller = MenuController(
            backend: DatabaseBackend(databasePath: databasePath),
            sync: { await worker.sync($0) })
        host = MenuHost(
            controller: controller,
            setup: SetupController(setup: .forBundle(), preferences: UserDefaultsSetupPreferences()),
            language: language)
        host.onQuit = { NSApp.terminate(nil) }
        host.onSetLaunchAtLogin = { [unowned self] in setLaunchAtLogin($0) }
        refreshLaunchAtLogin()
    }

    func start() {
        let presenter = StatusItemController(host: host)
        self.presenter = presenter
        controller.closePopover = { [presenter] in presenter.close() }
        controller.presentPopover = { [presenter] in presenter.present() }
        host.onClose = { [presenter] in presenter.close() }

        let hotKey = GlobalHotKey { [presenter] in presenter.toggle() }
        self.hotKey = hotKey
        host.hotKeyStatus = hotKey.status

        controller.start(databasePath: databasePath)
    }

    func handleReopen() { presenter?.handleReopen() }

    /// 실행 인자 처리: `--login-item on|off|status`는 결과를 `~/Library/Logs/jtm/app.log`에 남기고 앱은 그대로 돈다.
    func applyLaunchArguments(_ arguments: [String]) {
        let argument = LoginItemArgument.parse(arguments)
        guard argument != .none else { return }
        let log = AppLog.standard()
        LoginItemRunner.run(argument, service: SystemLoginItemService(), log: { log.append($0) })
        refreshLaunchAtLogin()
    }

    // MARK: Launch at login

    func refreshLaunchAtLogin() {
        host.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            host.launchAtLoginError = nil
            if enabled, SMAppService.mainApp.status == .requiresApproval {
                // ad-hoc 서명 앱은 사용자가 시스템 설정에서 한 번 허용해야 한다.
                host.launchAtLoginError = L10n.string(.loginItemNeedsApproval)
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            host.launchAtLoginError = "\(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }
}

/// 실제 `SMAppService.mainApp`. 테스트에서는 쓰지 않는다(등록하면 로그인 항목이 바뀐다).
private struct SystemLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}
