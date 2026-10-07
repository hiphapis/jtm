import JTMAppCore
import SwiftUI

/// 푸터 "?" 버튼이 여는 범례: 목적지 아이콘, 상태와 이유, 행 버튼. 문구는 모두 `Legend`(JTMAppCore)에서 온다.
struct LegendView: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string(.legendTitle)).font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L10n.string(.legendCloseHelp))
                    .accessibilityLabel(L10n.string(.legendCloseLabel))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    block(L10n.string(.legendDestinations), Legend.destinations)
                    block(L10n.string(.legendStatuses), Legend.statuses)
                    block(L10n.string(.legendButtons), Legend.actions)
                    Text(L10n.string(.legendFootnote))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
            }
        }
    }

    private func block(_ title: String, _ entries: [LegendEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        if let symbol = entry.symbol {
                            Image(systemName: symbol)
                        } else {
                            Color.clear.frame(height: 1)  // 높이를 늘리지 않는 빈 칸(들여쓰기 맞춤)
                        }
                    }
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                    // 이름과 설명을 한 덩어리 글로 이어서, 길어서 줄이 바뀌어도 높이 계산이 어긋나지 않게 한다.
                    (Text(entry.title).font(.callout.weight(.medium)) + Text("  ")
                        + Text(entry.detail).font(.caption).foregroundColor(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
