import Carbon.HIToolbox
import Foundation
import WWIAppCore

/// Carbon `RegisterEventHotKey`: 손쉬운 사용 권한이 필요 없다. C 콜백이라 캡처할 수 없어서 전역 슬롯을 거친다.
nonisolated(unsafe) private var hotKeyAction: (@Sendable () -> Void)?

private func hotKeyHandler(_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async { hotKeyAction?() }
    return noErr
}

/// 등록은 `kEventHotKeyExclusive`로 한다: 옵션 0으로 등록하면 다른 앱과 같은 조합이 둘 다 `noErr`로 성공해서 충돌을 알 수 없다
/// (P3-R S2 실측). exclusive끼리는 나중 등록이 `eventHotKeyExistsErr`로 실패하지만, 상대가 exclusive가 아니면 여전히
/// 감지할 수 없다: "이미 쓰는 중"을 완전히 알아내는 방법은 없다.
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var status: HotKeyStatus

    /// 기본은 ⌥⌘J.
    init(
        keyCode: Int = kVK_ANSI_J, modifiers: Int = optionKey | cmdKey, label: String = "⌥⌘J",
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        status = .failed(label: label, code: Int32(eventNotHandledErr))
        hotKeyAction = { MainActor.assumeIsolated { action() } }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, &handlerRef)
        guard installed == noErr else {
            status = .failed(label: label, code: installed)
            return
        }
        let id = EventHotKeyID(signature: OSType(0x4A54_4D31), id: 1)  // 'JTM1'
        let registered = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKeyRef)
        if registered == noErr {
            status = .registered(label: label)
        } else {
            status = .failed(label: label, code: registered)
            unregister()  // 등록 못 한 핸들러를 남기지 않는다
            hotKeyAction = nil
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
