import WWIAppCore
import WWICore
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
        header(L10n.string(.setupTitle), symbol: "wrench.and.screwdriver")
        Text(L10n.string(.setupIntro))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 3) {
            if status.link != .ok {
                bullet(L10n.string(.setupLinkBullet, setup.setup.display(setup.setup.linkPath)))
            }
            if status.legacyLink {
                bullet(L10n.string(.setupLegacyLinkBullet, setup.setup.display(setup.setup.legacyLinkPath)))
            }
            hookBullet(status.claude, agent: .claude, file: "~/.claude/settings.json")
            hookBullet(status.codex, agent: .codex, file: "~/.codex/hooks.json")
            bullet(L10n.string(.setupSafetyNote), dim: true)
        }
        HStack {
            Spacer()
            Button(L10n.string(.setupLater)) { setup.later() }
                .keyboardShortcut(.cancelAction)
            Button(L10n.string(.setupInstall)) { Task { await setup.install() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(setup.isWorking)
        }
    }

    @ViewBuilder private func hookBullet(_ state: AgentHooksState, agent: HookAgent, file: String) -> some View {
        let name = CLISetup.agentName(agent)
        switch state {
        case .needsInstall:
            bullet(L10n.string(.setupAddHooksBullet, name, file))
        case .needsMigration:
            bullet(L10n.string(.setupMigrateHooksBullet, name, file))
        case .unreadable(let reason):
            bullet(L10n.string(.setupUnreadableBullet, name, reason), warn: true)
        case .installed:
            bullet(L10n.string(.setupInstalledBullet, name), dim: true)
        case .notPresent:
            bullet(L10n.string(.setupNotFoundBullet, name), dim: true)
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
        header(L10n.string(.setupAllSetTitle), symbol: "checkmark.circle")
        Text(L10n.string(.setupAllSetBody, setup.setup.display(setup.setup.linkPath)))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button(L10n.string(.setupClose)) { setup.dismissResult() }.keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Finished

    @ViewBuilder private func finished(_ result: SetupResult, action: SetupController.Action) -> some View {
        if let error = result.error {
            header(L10n.string(action == .install ? .setupFailedInstall : .setupFailedRemove), symbol: "exclamationmark.triangle")
            Text(error).foregroundStyle(Color.red).fixedSize(horizontal: false, vertical: true)
            Text(L10n.string(.setupFailedNote))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            header(L10n.string(action == .install ? .setupDoneInstall : .setupDoneRemove), symbol: "checkmark.circle")
        }
        VStack(alignment: .leading, spacing: 3) {
            ForEach(result.lines, id: \.self) { bullet($0) }
        }
        if result.wroteCodexHooks {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SetupNotices.codexTrust, id: \.self) { line in
                    Text(line.trimmingCharacters(in: .whitespaces)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Color.orange)
        }
        HStack {
            Spacer()
            Button(L10n.string(.setupOK)) { setup.dismissResult() }.keyboardShortcut(.defaultAction)
        }
    }
}
