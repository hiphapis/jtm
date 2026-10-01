import AppKit
import JTMAppCore
import JTMAppUI
import SwiftUI

// 개발용 진단 도구(앱 번들에 넣지 않는다): `JTM_DB_PATH=<db> swift run JTMSnapshot out.png`는 팝오버 본문을 화면 밖에서
// 그려 PNG로 저장하고 끝난다(사용자 화면과 입력을 건드리지 않는다). 실제 DB를 열지 않도록 `JTM_DB_PATH`가 꼭 있어야 한다.
// `--hidden`을 주면 메뉴바 아이콘이 숨겨졌을 때의 안내 문구가 붙은 모습을 그린다.
// 증거용 옵션: `--seed`는 합성 티켓을 새 DB에 써 넣고(이미 있는 파일에는 쓰지 않는다), `--legend`는 "?" 범례를 연 모습,
// `--archive`는 보관함을, `--done`은 "최근 완료"를 펼친 모습(완료 행의 ✓은 꺼져 있다), `--undo`는 방금 🗑을 눌러 푸터에 "되돌리기"가 보이는 모습, `--height N`은 세로 크기다.
// `--select N`은 N번째(1부터) 보이는 행을 선택한 모습이다(강조색이 깔린다). 행 버튼은 선택·호버와 상관없이 모든 행에 늘 보인다.
// 화면 밖 렌더링에는 마우스가 없어서 버튼의 호버(더 진한 색) 모습은 그려지지 않는다.
// `--setup`은 첫 실행 카드("CLI와 훅 설치")가 맨 위에 보이는 모습이고, `--setup-done`은 [설치]를 누른 뒤의 결과 카드다.
// 둘 다 임시 HOME(`~/.claude`, `~/.codex` 폴더만 있는)과 가짜 번들 안 jtm으로 진짜 설치 코드를 돌린다: 진짜 홈은 건드리지 않는다.
// `--confirm`은 선택한 행(⭐/next_action/note가 있어야 한다)에서 🗑을 한 번 눌러 "정말 지울까요?"를 묻는 모습이다.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let output = arguments.first(where: { !$0.hasPrefix("--") }) else {
    fail("usage: JTM_DB_PATH=<db> JTMSnapshot <out.png> [--hidden]")
}
guard let databasePath = ProcessInfo.processInfo.environment["JTM_DB_PATH"], !databasePath.isEmpty else {
    fail("JTM_DB_PATH is required (this tool never touches the real database)")
}
let showHidden = arguments.contains("--hidden")
let seed = arguments.contains("--seed")
let showLegend = arguments.contains("--legend")
let showArchive = arguments.contains("--archive")
let showUndo = arguments.contains("--undo")
let showConfirm = arguments.contains("--confirm")
let showDone = arguments.contains("--done")
let showSetupDone = arguments.contains("--setup-done")
let showSetup = arguments.contains("--setup") || showSetupDone
let selectIndex = arguments.firstIndex(of: "--select").flatMap { index in
    arguments.indices.contains(index + 1) ? Int(arguments[index + 1]) : nil
}
let height = arguments.firstIndex(of: "--height").flatMap { index in
    arguments.indices.contains(index + 1) ? Double(arguments[index + 1]) : nil
} ?? Double(PopoverMetrics.height)
if seed {
    do { try Seed.write(to: databasePath) } catch { fail("\(error)") }
}

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.prohibited)
    Task { @MainActor in
        let controller = MenuController(backend: DatabaseBackend(databasePath: databasePath))
        await controller.reload()
        if showArchive { controller.toggle(.archive) }
        if showDone { controller.toggle(.done) }
        if showLegend { controller.toggleLegend() }
        if showUndo, let first = controller.sections.first?.rows.last { controller.ignore(first.id) }
        if let selectIndex {
            let ids = controller.state.selectableIds(now: controller.now)
            if ids.indices.contains(selectIndex - 1) { controller.select(ids[selectIndex - 1]) }
        }
        if showConfirm, let selected = controller.state.selectedId { controller.requestIgnore(selected) }
        var setup: SetupController?
        var sandbox: String?
        if showSetup {
            let root = NSTemporaryDirectory() + "jtm-snapshot-home-\(UUID().uuidString)"
            let helper = root + "/JTM.app/Contents/Helpers/jtm"
            for directory in [root + "/home/.claude", root + "/home/.codex", (helper as NSString).deletingLastPathComponent] {
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            FileManager.default.createFile(atPath: helper, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
            sandbox = root
            let controller = SetupController(
                setup: CLISetup(home: root + "/home", helperPath: helper), preferences: InMemorySetupPreferences())
            if showSetupDone { await controller.install() }
            setup = controller
        }
        let host = MenuHost(controller: controller, setup: setup)
        host.hotKeyStatus = .registered(label: "⌥⌘J")
        host.iconHidden = showHidden
        let view = NSHostingView(rootView: MenuContentView(host: host, height: height))
        view.frame = NSRect(x: 0, y: 0, width: PopoverMetrics.width, height: height)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do { try png.write(to: URL(fileURLWithPath: output)) } catch { fail("snapshot failed: \(error)") }
        if let sandbox { try? FileManager.default.removeItem(atPath: sandbox) }
        print("wrote \(output)")
        exit(0)
    }
    NSApplication.shared.run()
}
