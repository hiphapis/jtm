import JTMAppCore
import JTMCore
import SwiftUI

/// 팝오버 본문. 상태와 동작은 모두 `MenuController`에 있고, 여기서는 그리고 키 입력을 넘기기만 한다.
public struct MenuContentView: View {
    let host: MenuHost
    /// 팝오버 높이(기본 `PopoverMetrics.height`). 진단 도구가 더 긴 목록을 한 장에 담을 때만 바꾼다.
    let height: CGFloat
    private var controller: MenuController { host.controller }
    @FocusState private var searchFocused: Bool

    public init(host: MenuHost, height: CGFloat = PopoverMetrics.height) {
        self.host = host
        self.height = height
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let setup = host.setup, setup.isVisible {
                SetupCardView(setup: setup)
                Divider()
            }
            searchField
            Divider()
            if controller.showLegend {
                LegendView { controller.toggleLegend() }
            } else {
                list
            }
            Divider()
            FooterView(host: host)
        }
        .frame(width: PopoverMetrics.width, height: height)
        .background { shortcuts }
        .onAppear { focusSearch() }
        .onChange(of: controller.focusToken) {
            host.setup?.refresh()  // 열 때마다 파일 상태를 다시 본다(그사이 링크나 훅이 바뀌었을 수 있다)
            focusSearch()
        }
        .onChange(of: controller.editing == nil) { _, notEditing in if notEditing { focusSearch() } }
    }

    private func focusSearch() {
        DispatchQueue.main.async { searchFocused = true }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(
                "제목, 프로젝트, next_action 검색",
                text: Binding(get: { controller.state.query }, set: { controller.setQuery($0) })
            )
            .textFieldStyle(.plain)
            .focused($searchFocused)
            .onSubmit { Task { await controller.activateSelected() } }
            .onKeyPress(.upArrow) { controller.moveSelection(by: -1); return .handled }
            .onKeyPress(.downArrow) { controller.moveSelection(by: 1); return .handled }
            .onKeyPress(.escape) { handleEscape() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func handleEscape() -> KeyPress.Result {
        if controller.showLegend {
            controller.toggleLegend()
        } else if controller.confirmIgnoreId != nil {
            controller.cancelIgnoreConfirmation()
        } else if controller.editing != nil {
            controller.cancelEdit()
        } else if !controller.state.query.isEmpty {
            controller.setQuery("")
        } else {
            host.close()
        }
        return .handled
    }

    /// 선택한 행의 단축키는 컨텍스트 메뉴가 닫혀 있어도 먹어야 해서 보이지 않는 버튼에 건다: ⌘D 완료, ⌘E next_action 편집,
    /// ⌘S 유지(⭐) 토글, ⌘⌫ 무시(⭐/next_action/note가 있으면 한 번 더 눌러 확인), ⌘R 되살리기(보관함 행).
    /// ⌘⌫는 글자 입력 중에는 먹지 않는다(검색어나 편집 중인 글을 줄 처음까지 지우는 기본 동작을 가로채 티켓을 지우면 안 된다).
    private var shortcuts: some View {
        Group {
            Button("완료") { Task { await controller.markDoneSelected() } }
                .keyboardShortcut("d", modifiers: .command)
            Button("next_action 편집") { controller.beginEdit(.nextAction) }
                .keyboardShortcut("e", modifiers: .command)
            Button("유지 토글") { Task { await controller.toggleKeepSelected() } }
                .keyboardShortcut("s", modifiers: .command)
            Button("무시") { controller.ignoreSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(controller.editing != nil || !controller.state.trimmedQuery.isEmpty)
            Button("되살리기") { Task { await controller.restoreSelected() } }
                .keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        let sections = controller.sections
        if sections.isEmpty {
            Spacer()
            Text(controller.state.trimmedQuery.isEmpty ? "티켓이 없어요" : "일치하는 티켓이 없어요")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Spacer()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            SectionHeader(section: section) { controller.toggle(section.section) }
                            ForEach(section.visibleRows) { row in
                                TicketRowView(row: row, controller: controller)
                                    .id(row.id)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: controller.state.selectedId) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }
}

private struct SectionHeader: View {
    let section: MenuSectionModel
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if section.section.isCollapsible {
                Image(systemName: section.collapsed ? "chevron.right" : "chevron.down").font(.caption2)
            }
            Text(section.section.title)
            // 보관함은 "보관함 (N)"으로 보인다.
            Text(section.section == .archive ? "(\(section.rows.count))" : "\(section.rows.count)").foregroundStyle(.tertiary)
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .onTapGesture { if section.section.isCollapsible { toggle() } }
    }
}

// MARK: Row

struct TicketRowView: View {
    let row: MenuRow
    let controller: MenuController
    @FocusState private var editFocused: Bool
    @State private var hovering = false
    /// 마우스를 누른 순간의 행 id와 시각. 손을 뗄 때 이 값으로 동작을 부른다(그 사이 목록이 리플로돼도 다음 행으로 옮겨 가지 않는다).
    @State private var press: (id: Int64, at: TimeInterval)?

    private var isSelected: Bool { controller.state.selectedId == row.id }
    private var editing: EditSession? { controller.editing?.ticketId == row.id ? controller.editing : nil }
    private var feedback: Feedback? { controller.feedback?.ticketId == row.id ? controller.feedback : nil }
    private var confirming: Bool { controller.confirmIgnoreId == row.id }
    private var tint: Color {
        isSelected ? Color.accentColor.opacity(0.18) : (hovering ? Color.primary.opacity(0.05) : Color.clear)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.destination?.symbolName ?? "questionmark.circle")
                .frame(width: 16)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
                .help(row.destinationHelp)
                .accessibilityLabel(row.destinationHelp)
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                secondLine
                if let feedback {
                    Text(feedback.message)
                        .font(.caption)
                        .foregroundStyle(feedback.isError ? Color.red : Color.secondary)
                        .lineLimit(3)
                }
            }
            // 버튼은 모든 행에 늘 보인다(호버·선택과 무관). 입력창을 연 행에서만 숨긴다: 편집 중에 ✎를 누르면 초안이 새로 시작돼 버린다.
            if editing == nil { rowButtons }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { Task { await controller.activate(row.id) } }
        .contextMenu { contextMenu }
        .accessibilityElement(children: editing == nil ? .ignore : .contain)
        .accessibilityLabel(row.accessibilityLabel(now: controller.now))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { Task { await controller.activate(row.id) } }
        .accessibilityActions { accessibilityRowActions }
    }

    @ViewBuilder private var titleLine: some View {
        if let editing, editing.field == .title {
            editor("제목", text: editing.draft)
        } else {
            HStack(spacing: 6) {
                // 상태칩과 시간은 줄어들거나 줄바꿈하지 않는다(fixedSize). 나머지 폭은 전부 제목이 쓴다
                // (프로젝트는 둘째 줄로 내렸고, 버튼 4개 자리는 행 오른쪽에 따로 잡혀 있다).
                Text(row.title).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                Spacer(minLength: 4)
                if let reason = row.reasonLabel {
                    Text(reason)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.22)))
                        .foregroundStyle(Color.orange)
                        .fixedSize()
                        .help(row.reasonHelp ?? "")
                }
                Text(row.ago(now: controller.now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder private var secondLine: some View {
        if let editing, editing.field == .nextAction {
            editor("next_action", text: editing.draft)
        } else if row.project != nil || row.nextAction != nil {
            // "[project] · next_action". 프로젝트만 있거나 next_action만 있으면 그것만, 둘 다 없으면 줄 자체가 없다.
            // 프로젝트는 최대 120pt(넘으면 가운데를 줄인다), 나머지 폭은 next_action이 쓴다.
            HStack(spacing: 4) {
                if let project = row.project {
                    Text("[\(project)]")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 120, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if row.project != nil && row.nextAction != nil { Text("·") }
                if let next = row.nextAction {
                    Text(next).lineLimit(1).truncationMode(.tail)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func editor(_ prompt: String, text: String) -> some View {
        TextField(prompt, text: Binding(get: { controller.editing?.draft ?? text }, set: { controller.editing?.draft = $0 }))
            .textFieldStyle(.roundedBorder)
            .focused($editFocused)
            .onSubmit { Task { await controller.commitEdit() } }
            .onKeyPress(.escape) { controller.cancelEdit(); return .handled }
            .onAppear { DispatchQueue.main.async { editFocused = true } }
    }

    // MARK: Row buttons

    /// 행 오른쪽의 버튼들(항상 보인다). 버튼 칸(22pt)이 글줄보다 커서 위아래 여백을 깎아, 행 높이는 버튼이 없을 때와 같다(누르는 범위는 그대로).
    /// 보관함 행은 "되살리기"만 있다. 🗑을 한 번 눌러 확인을 묻는 중이면 "정말 지울까요?" 한 개(+취소)로 바뀐다.
    private var rowButtons: some View {
        HStack(spacing: 0) {
            if confirming {
                Button { act(.ignore) } label: {
                    Text(RowAction.ignoreConfirmLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.red.opacity(0.14)))
                }
                .buttonStyle(RowIconButtonStyle(onPressChange: pressChanged))
                .help(RowAction.ignoreConfirmHelp)
                .accessibilityLabel(RowAction.ignoreConfirmLabel)
                .accessibilityHint(RowAction.ignoreConfirmHelp)
                Button { controller.cancelIgnoreConfirmation() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22)
                }
                .buttonStyle(RowIconButtonStyle())
                .help("취소 (Esc)")
                .accessibilityLabel("취소")
            } else if row.archived {
                Button { act(.restore) } label: {
                    Label(RowAction.restore.label, systemImage: RowAction.restore.symbolName())
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                }
                .buttonStyle(RowIconButtonStyle(onPressChange: pressChanged))
                .help(RowAction.restore.help())
                .accessibilityLabel(RowAction.restore.accessibilityLabel)
            } else {
                ForEach(RowAction.rowActions, id: \.self) { action in
                    if action == .keep {
                        keepButton
                    } else {
                        Button { act(action) } label: {
                            Image(systemName: action.symbolName(kept: row.kept))
                                .font(.system(size: 12))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(RowIconButtonStyle(onPressChange: pressChanged))
                        .disabled(action == .done && row.status == .done)
                        .help(action.help(kept: row.kept))
                        .accessibilityLabel(action.accessibilityLabel)
                        .accessibilityHint(action.help(kept: row.kept))
                    }
                }
            }
        }
        .padding(.vertical, -3)
    }

    private var keepButton: some View {
        Button { act(.keep) } label: {
            Image(systemName: RowAction.keep.symbolName(kept: row.kept))
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(RowIconButtonStyle(
            rest: row.kept ? Color.yellow : Color.secondary, hover: row.kept ? Color.yellow : Color.primary,
            onPressChange: pressChanged))
        .help(RowAction.keep.help(kept: row.kept))
        .accessibilityLabel(RowAction.keep.accessibilityLabel)
        .accessibilityValue(RowAction.keep.accessibilityValue(kept: row.kept) ?? "")
        .accessibilityHint(RowAction.keep.help(kept: row.kept))
        .accessibilityAddTraits(.isToggle)
    }

    /// 마우스를 누른 순간을 기록한다(손을 뗄 때 `act`가 이 행 id와 시각으로 부른다).
    private func pressChanged(_ pressed: Bool) {
        if pressed { press = (row.id, controller.pressTimestamp()) }
    }

    /// 버튼을 눌렀다: 마우스를 누른 순간의 행 id와 시각으로 컨트롤러에 맡긴다(키보드/VoiceOver로 누르면 지금 행과 지금 시각).
    private func act(_ action: RowAction) {
        let captured = press
        press = nil
        let id = captured?.id ?? row.id
        Task { await controller.perform(action, on: id, pressedAt: captured?.at) }
    }

    @ViewBuilder private var accessibilityRowActions: some View {
        if row.archived {
            Button(RowAction.restore.label) { act(.restore) }
        } else {
            Button(row.kept ? "유지 해제" : "유지") { act(.keep) }
            Button(RowAction.editNextAction.label) { act(.editNextAction) }
            if row.status != .done { Button(RowAction.done.label) { act(.done) } }
            Button(confirming ? RowAction.ignoreConfirmLabel : RowAction.ignore.label) { act(.ignore) }
        }
    }

    @ViewBuilder private var contextMenu: some View {
        Button("이동") { Task { await controller.activate(row.id) } }
        Divider()
        if row.archived {
            Button(RowAction.restore.label) { act(.restore) }
                .keyboardShortcut("r", modifiers: .command)
        } else {
            if row.status != .done {
                Button("완료") { Task { await controller.setStatus(row.id, .done) } }
                    .keyboardShortcut("d", modifiers: .command)
            }
            Button(row.kept ? "유지 해제" : "유지(⭐)") { act(.keep) }
                .keyboardShortcut("s", modifiers: .command)
        }
        Menu("상태 변경") {
            ForEach(TicketStatus.allCases.filter { $0 != row.status }, id: \.self) { status in
                Button(Self.statusName(status)) { Task { await controller.setStatus(row.id, status) } }
            }
        }
        Button("next_action 편집") { controller.beginEdit(.nextAction, id: row.id) }
            .keyboardShortcut("e", modifiers: .command)
        Button("제목 편집 (고정됨)") { controller.beginEdit(.title, id: row.id) }
        if !row.archived {
            Divider()
            Button(confirming ? RowAction.ignoreConfirmLabel : "무시…", role: .destructive) { act(.ignore) }
                .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    private static func statusName(_ status: TicketStatus) -> String {
        switch status {
        case .waiting: "내 입력 대기"
        case .active: "진행 중"
        case .inbox: "Inbox"
        case .blocked: "Blocked"
        case .done: "완료"
        }
    }
}

// MARK: Footer

struct FooterView: View {
    let host: MenuHost

    static let hiddenIconHint = "메뉴바 아이콘이 숨겨져 있어요 — 시스템 설정 > 메뉴 막대에서 JTM을 허용하세요"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let undo = host.controller.undoNotice {
                HStack(spacing: 6) {
                    let more = host.controller.pendingIgnores.count - 1
                    Text("“\(undo.title)”을(를) 무시했어요" + (more > 0 ? " 외 \(more)건" : "")).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Button("되돌리기") { host.controller.undoIgnore() }
                        .buttonStyle(.link)
                        .help("방금 무시한 티켓을 되살려요 (5초 안에서만)")
                }
            }
            if host.iconHidden {
                Text(Self.hiddenIconHint)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let error = host.controller.loadError {
                    Text("목록을 읽지 못했어요: \(error)").foregroundStyle(.red).lineLimit(1)
                } else if let notice = host.controller.footerNotice {
                    Text(notice).foregroundStyle(.secondary)
                }
                if let error = host.launchAtLoginError {
                    Text(error).foregroundStyle(.red).lineLimit(1)
                }
                Spacer()
                shortcutLabel
                Button { host.controller.toggleLegend() } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(host.controller.showLegend ? Color.accentColor : Color.secondary)
                .help("아이콘과 상태 설명 보기")
                .accessibilityLabel("아이콘과 상태 설명")
                .accessibilityValue(host.controller.showLegend ? "열림" : "닫힘")
                Menu {
                    Toggle("로그인 시 자동 실행", isOn: Binding(
                        get: { host.launchAtLogin }, set: { host.setLaunchAtLogin($0) }))
                    Button("지금 동기화") { Task { await host.controller.runSync(.manual) } }
                    if let setup = host.setup {
                        Divider()
                        Button("CLI·훅 설정…") { setup.show() }
                        Button("훅 제거") { Task { await setup.removeHooks() } }
                    }
                    Divider()
                    Button("종료") { host.quit() }
                        .keyboardShortcut("q", modifiers: .command)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("설정 메뉴")
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// 현재 단축키. 등록하지 못했으면 이유를 빨갛게 보인다.
    @ViewBuilder private var shortcutLabel: some View {
        if let status = host.hotKeyStatus {
            if let problem = status.problem {
                Text(problem).foregroundStyle(.red).lineLimit(1)
            } else {
                Text(status.label).foregroundStyle(.tertiary)
            }
        }
    }
}

/// 행 버튼의 모양: 평소에는 `rest` 색, 마우스를 올리면 `hover` 색과 옅은 바탕, 누르면 더 짙은 바탕이 깔린다.
/// 마우스를 누른 순간(`isPressed`가 켜질 때)을 `onPressChange`로 알린다.
private struct RowIconButtonStyle: ButtonStyle {
    var rest: Color = .secondary
    var hover: Color = .primary
    var onPressChange: (Bool) -> Void = { _ in }

    func makeBody(configuration: Configuration) -> some View {
        RowIconButtonBody(configuration: configuration, rest: rest, hover: hover, onPressChange: onPressChange)
    }
}

/// 호버 여부를 들고 있어야 해서 `ButtonStyle`이 아니라 뷰로 뺐다(스타일 값 자체는 상태를 가질 수 없다).
private struct RowIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let rest: Color
    let hover: Color
    let onPressChange: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var lit: Bool { hovering && isEnabled }

    var body: some View {
        configuration.label
            .foregroundStyle(lit ? hover : rest)
            .opacity(isEnabled ? 1 : 0.35)  // 이미 완료한 행의 ✓처럼 눌러도 소용없는 버튼은 흐리게
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (lit ? 0.07 : 0))))
            .onHover { hovering = $0 }
            .onChange(of: configuration.isPressed) { _, pressed in onPressChange(pressed) }
    }
}
