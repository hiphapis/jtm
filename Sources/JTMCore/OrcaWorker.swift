import Foundation

/// Orca 오케스트레이션 워커 세션을 알아보는 규칙(`docs/01-product/auto-capture.md`의 "오케스트레이션 워커 세션은 수집하지 않는다").
/// 워커는 사람이 관리할 일이 아니라서 티켓을 만들지 않는다. 프로세스를 띄우지 않는 순수 규칙이다.
public enum OrcaWorker {
    /// 워커 안내문의 두 표지. 둘 다 프롬프트 앞부분에 있어야 워커로 본다.
    public static let promptMarkers = ["You are working inside Orca, a multi-agent IDE", "dispatched worker"]
    /// 프롬프트에서 표지를 찾는 앞부분의 길이(문자 수). Claude는 안내문을 "Please carry out…"로 감싸 붙여넣지만 표지는 여전히 앞에 있다.
    public static let promptScanLimit = 2000
    /// 워커 티켓의 제목이 시작하는 말(제목은 프롬프트 앞 60자다). 이미 쌓인 티켓을 정리할 때(`jtm prune workers`) 쓴다.
    public static let titlePrefixes = ["You are working inside Orca", "Please carry out this task from my Orca coordinator"]

    public static let promptReason = "orca-worker-prompt"
    public static let handleReason = "orca-worker-handle"
    public static let titleReason = "orca-worker-title"
    public static let sessionReason = "ignored-session"

    public static func isWorkerPrompt(_ prompt: String) -> Bool {
        let head = String(prompt.prefix(promptScanLimit))
        return promptMarkers.allSatisfy { head.contains($0) }
    }

    public static func hasWorkerTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return titlePrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// 사용자가 손대지 않은 티켓인가: 상태가 inbox/active/waiting이고 고정 제목, `next_action`, `note`, `priority`가 없고 유지(⭐)가 아니다.
    /// (`blocked`와 `done`은 사용자가 정한 상태로 본다.) 세션 위치는 호출하는 쪽이 따로 본다.
    public static func isUntouched(_ ticket: Ticket) -> Bool {
        [.inbox, .active, .waiting].contains(ticket.status) && !ticket.pinnedTitle && !ticket.kept
            && ticket.nextAction == nil && ticket.note == nil && ticket.priority == nil
    }

    /// 에이전트 세션 위치(`claude_code`, `codex_thread`)의 키.
    static func sessionKeys(of locations: [Location]) -> [String] {
        locations.compactMap { $0.kind == .claudeCode || $0.kind == .codexThread ? $0.externalKey : nil }
    }

    /// 워커로 판정된 티켓을 사용자가 손대지 않았으면 지우고(위치는 함께 지워진다) 그 세션 키를 무시 목록에 남긴다.
    /// `ownKey`를 주면 그 밖의 세션 위치가 붙은 티켓은 남긴다(다른 세션의 흔적이라서). 지웠으면 세션 키들을, 남겼으면 nil을 돌려준다.
    /// 호출하는 쪽이 트랜잭션을 잡는다.
    @discardableResult
    static func removeIfUntouched(ticketId: Int64, store: Store, ownKey: String? = nil, reason: String) throws -> [String]? {
        guard let ticket = try? store.getTicket(id: ticketId), isUntouched(ticket) else { return nil }
        let keys = sessionKeys(of: try store.locations(ticketId: ticketId))
        if let ownKey, keys.contains(where: { $0 != ownKey }) { return nil }
        for key in keys { try store.ignoreSession(key, reason: reason) }
        try store.deleteTicket(id: ticketId)
        return keys
    }
}
