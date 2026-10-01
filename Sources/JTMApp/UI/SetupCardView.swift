import JTMAppCore
import JTMCore
import SwiftUI

/// 팝오버 맨 위의 "CLI와 훅 설치" 카드. 무엇이 바뀌는지 먼저 보여 주고, [설치]를 눌러야만 파일을 쓴다.
struct SetupCardView: View {
    let setup: SetupController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch setup.mode {
            case .offer(let status): offer(status)
            case .allSet: allSet
            case .finished(let result, let action): finished(result, action: action)
            case nil: EmptyView()
            }
        }
        .font(.caption)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.25)))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func header(_ title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
            Text(title).font(.headline)
        }
    }

    // MARK: Offer

    @ViewBuilder private func offer(_ status: SetupStatus) -> some View {
        header("CLI와 훅 설치", symbol: "wrench.and.screwdriver")
        Text("에이전트의 진행 상황이 자동으로 JTM에 모이려면 아래 항목이 필요해요. 설치를 누르기 전에는 아무 파일도 바꾸지 않아요.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 3) {
            if status.link != .ok {
                bullet("\(setup.setup.display(setup.setup.linkPath))에 앱 안의 jtm을 연결해요 (필요하면 폴더를 만들어요)")
            }
            hookBullet(status.claude, agent: .claude, file: "~/.claude/settings.json")
            hookBullet(status.codex, agent: .codex, file: "~/.codex/hooks.json")
            bullet("jtm이 관리하는 항목만 추가하고, 이미 있던 설정은 그대로 둬요. 파일을 바꾸기 전에 백업을 남겨요.", dim: true)
        }
        HStack {
            Spacer()
            Button("나중에") { setup.later() }
                .keyboardShortcut(.cancelAction)
            Button("설치") { Task { await setup.install() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(setup.isWorking)
        }
    }

    @ViewBuilder private func hookBullet(_ state: AgentHooksState, agent: HookAgent, file: String) -> some View {
        let name = CLISetup.agentName(agent)
        switch state {
        case .needsInstall:
            bullet("\(file)에 \(name) 훅(jtm 항목)을 추가해요")
        case .unreadable(let reason):
            bullet("\(name) 설정을 읽을 수 없어서 건드리지 않아요 — \(reason)", warn: true)
        case .installed:
            bullet("\(name) 훅은 이미 설치돼 있어요", dim: true)
        case .notPresent:
            bullet("\(name)를 찾지 못했어요 — 훅은 건너뛰어요", dim: true)
        }
    }

    private func bullet(_ text: String, dim: Bool = false, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(warn ? Color.orange : (dim ? Color.secondary : Color.primary))
    }

    // MARK: Already set

    @ViewBuilder private var allSet: some View {
        header("CLI와 훅이 설치돼 있어요", symbol: "checkmark.circle")
        Text("\(setup.setup.display(setup.setup.linkPath))가 이 앱의 jtm을 가리키고, 훅이 모두 들어 있어요. 훅을 빼려면 ⋯ 메뉴의 \"훅 제거\"를 쓰세요.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("닫기") { setup.dismissResult() }.keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Finished

    @ViewBuilder private func finished(_ result: SetupResult, action: SetupController.Action) -> some View {
        if let error = result.error {
            header(action == .install ? "설치하지 못했어요" : "훅을 제거하지 못했어요", symbol: "exclamationmark.triangle")
            Text(error).foregroundStyle(Color.red).fixedSize(horizontal: false, vertical: true)
            Text("아무것도 덮어쓰지 않았어요. 문제를 고친 뒤 ⋯ 메뉴의 \"CLI·훅 설정…\"에서 다시 시도하세요.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            header(action == .install ? "설치했어요" : "훅을 제거했어요", symbol: "checkmark.circle")
        }
        VStack(alignment: .leading, spacing: 3) {
            ForEach(result.lines, id: \.self) { bullet($0) }
        }
        if result.wroteCodexHooks {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(HookNotices.codexTrust.prefix(2)), id: \.self) { line in
                    Text(line.trimmingCharacters(in: .whitespaces)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Color.orange)
        }
        HStack {
            Spacer()
            Button("확인") { setup.dismissResult() }.keyboardShortcut(.defaultAction)
        }
    }
}
