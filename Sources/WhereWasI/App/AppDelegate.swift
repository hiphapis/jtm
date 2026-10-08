import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppRuntime.shared.start()
        AppRuntime.shared.applyLaunchArguments(CommandLine.arguments)
    }

    /// 되돌리기 시간이 안 끝난 무시(🗑)가 있으면 종료 전에 확정한다(안 그러면 티켓이 다시 보인다).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = AppRuntime.shared.controller
        guard !controller.pendingIgnores.isEmpty else { return .terminateNow }
        // DB 잠금에 걸려도 종료가 끌리지 않게 3초까지만 기다린다. 시간이 지나 못 끝낸 무시는 확정되지 않은 채 남지만
        // 안전한 쪽이다(티켓이 그대로 있다).
        let reply = TerminationReply()
        Task { @MainActor in
            await controller.flushPendingIgnores()
            reply.send()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            reply.send()
        }
        return .terminateLater
    }

    /// 실행 중인 앱을 다시 열면(Finder/Spotlight/`open`) 아이콘이 숨겨져 있어도 복구를 시도하고 내용을 보여 준다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppRuntime.shared.handleReopen()
        return false
    }
}

/// `terminateLater`에 한 번만 답한다(정상 종료와 시간 제한 중 먼저 오는 쪽).
@MainActor
private final class TerminationReply {
    private var sent = false

    func send() {
        guard !sent else { return }
        sent = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
