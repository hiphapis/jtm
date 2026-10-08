import AppKit

// SwiftUI `MenuBarExtra` 장면은 상태 아이템이 숨겨지면 앱을 끝내 버린다(P3-R B1). 그래서 AppKit `NSStatusItem`을 직접 쓴다.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
