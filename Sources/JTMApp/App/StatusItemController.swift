import AppKit
import JTMAppCore
import JTMAppUI
import Observation
import SwiftUI

/// 아이콘이 없어도 키를 받을 수 있는 앵커 없는 패널(테두리 없음).
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 메뉴바 상태 아이템, 팝오버, 그리고 아이콘이 숨겨졌을 때 대신 뜨는 패널.
/// - AppKit `NSStatusItem`은 SwiftUI `MenuBarExtra`와 달리 아이콘이 숨겨져도 앱을 끝내지 않는다.
/// - 열림/닫힘은 공개 API(`popoverDidShow`/`popoverDidClose`)로 받는다. 비공개 클래스 이름이나 `performClick`은 쓰지 않는다.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    static let autosaveName = "jtm.main"
    static let contentSize = NSSize(width: PopoverMetrics.width, height: PopoverMetrics.height)

    private let host: MenuHost
    private var controller: MenuController { host.controller }
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var panel: NSPanel?
    private var panelOpen = false
    private var visibilityObservation: NSKeyValueObservation?
    private var lastPopoverClose = ContinuousClock.Instant.now - .seconds(60)

    init(host: MenuHost) {
        self.host = host
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // SwiftUI가 붙이던 자동 이름(`Item-0`)은 생성 순서에 달려 있다. 고정 이름을 줘야 위치와 표시 설정이 유지된다.
        statusItem.autosaveName = Self.autosaveName
        configureButton()
        configurePopover()
        visibilityObservation = statusItem.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshHidden() }
        }
        observeBadge()
        // 버튼 창은 조금 뒤에야 붙는다: 시작 직후에 한 번 더 확인한다.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.refreshHidden()
        }
    }

    // MARK: Status item

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "JTM")
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.target = self
        button.action = #selector(buttonClicked)
        button.sendAction(on: [.leftMouseUp])
        updateBadge()
    }

    /// `waiting`이 1개 이상이면 개수를 아이콘 옆에 붙인다.
    private func updateBadge() {
        guard let button = statusItem.button else { return }
        let count = controller.badgeCount
        button.title = count > 0 ? " \(count)" : ""
        button.imagePosition = count > 0 ? .imageLeading : .imageOnly
        button.setAccessibilityLabel(count > 0 ? L10n.string(.statusItemWaiting, count) : "JTM")
    }

    /// `MenuController`는 `@Observable`이지만 AppKit은 구독하지 못한다: 관찰을 이어 걸며 배지를 갱신한다.
    private func observeBadge() {
        withObservationTracking {
            _ = controller.badgeCount
            _ = host.language?.choice  // 언어를 바꾸면 접근성 문구도 다시 쓴다
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateBadge()
                self?.observeBadge()
            }
        }
    }

    @objc private func buttonClicked() {
        // `.transient` 팝오버는 바깥(아이콘 포함)을 누르면 클릭 처리보다 먼저 닫힌다. 그 직후의 클릭은 "닫기"로 본다.
        if popover.isShown {
            popover.performClose(nil)
        } else if ContinuousClock.now - lastPopoverClose < .milliseconds(250) {
            return
        } else {
            _ = present()
        }
    }

    // MARK: Hidden icon

    /// 아이콘이 화면에 없는가: 시스템이 숨겼거나(`isVisible == false`), 버튼 창이 없거나, 창이 어느 화면에도 없다.
    private var iconIsHidden: Bool {
        guard statusItem.isVisible, let window = statusItem.button?.window else { return true }
        return window.screen == nil
    }

    private func refreshHidden() {
        let hidden = iconIsHidden
        if host.iconHidden != hidden { host.iconHidden = hidden }
    }

    // MARK: Present / close

    /// 단축키: 열려 있으면 닫고, 닫혀 있으면 연다.
    func toggle() {
        if controller.isOpen { close() } else { _ = present() }
    }

    /// 아이콘이 보이면 팝오버, 숨겨졌으면 같은 내용을 앵커 없는 패널로 띄운다. 열기를 시작했으면 true.
    func present() -> Bool {
        refreshHidden()
        if !host.iconHidden, showPopover() { return true }
        return showPanel()
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
        closePanel()
    }

    /// 재실행 이벤트: 아이콘이 숨겨져 있으면 다시 보이게 해 보고, 내용을 연다.
    func handleReopen() {
        if !statusItem.isVisible { statusItem.isVisible = true }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))  // 표시 상태가 반영될 시간
            guard let self, !self.controller.isOpen else { return }
            _ = self.present()
        }
    }

    // MARK: Popover

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = Self.contentSize
        let content = NSHostingController(rootView: MenuContentView(host: host))
        content.preferredContentSize = Self.contentSize
        popover.contentViewController = content
    }

    private func showPopover() -> Bool {
        guard let button = statusItem.button, button.window != nil else { return false }
        closePanel()
        guard !popover.isShown else { return true }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        return true
    }

    func popoverDidShow(_ notification: Notification) {
        controller.popoverOpened()
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = .now
        controller.popoverClosed()
    }

    // MARK: Panel (icon hidden)

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.contentSize), styleMask: [.borderless], backing: .buffered,
            defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.contentSize))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        let hosting = NSHostingView(rootView: MenuContentView(host: host))
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)
        panel.contentView = background
        return panel
    }

    private func showPanel() -> Bool {
        if panelOpen { return true }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = Self.contentSize
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 12))
        }
        panelOpen = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        controller.popoverOpened()
        return true
    }

    private func closePanel() {
        guard panelOpen else { return }
        panelOpen = false
        panel?.orderOut(nil)
        controller.popoverClosed()
    }

    /// 패널도 팝오버처럼 바깥을 누르면(키를 잃으면) 닫힌다.
    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        closePanel()
    }
}
