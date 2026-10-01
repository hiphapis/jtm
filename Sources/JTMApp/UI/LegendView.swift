import JTMAppCore
import SwiftUI

/// 푸터 "?" 버튼이 여는 범례: 목적지 아이콘, 상태와 이유, 행 버튼. 문구는 모두 `Legend`(JTMAppCore)에서 온다.
struct LegendView: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("아이콘과 상태 설명").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("범례 닫기 (Esc)")
                    .accessibilityLabel("범례 닫기")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    block("왼쪽 아이콘 — 어디로 이동하나", Legend.destinations)
                    block("상태와 이유", Legend.statuses)
                    block("행 오른쪽 버튼", Legend.actions)
                    Text("유지(⭐)가 아닌 티켓은 세션이 끝나면 완료로, 24시간 동안 활동이 없으면 보관함으로 가요.")
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
