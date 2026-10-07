import Foundation
import JTMAppCore
import JTMCore

/// `--seed`용 합성 티켓. 전부 가짜 제목/경로이고, 이름과 시각만 지금 기준으로 상대적이다.
/// 실제 DB를 건드리지 않도록 아직 없는 파일에만 쓴다. 제목, 다음 할 일, 프로젝트는 화면 언어(`L10n.current`)로 쓴다(한국어 데이터는 예전 그대로다).
enum Seed {
    enum SeedError: Error, CustomStringConvertible {
        case alreadyExists(String)
        var description: String {
            switch self {
            case .alreadyExists(let path): "refusing to seed an existing database: \(path)"
            }
        }
    }

    static func write(to path: String, now: Date = Date()) throws {
        guard !FileManager.default.fileExists(atPath: path) else { throw SeedError.alreadyExists(path) }
        let store = try Store(path: path, now: { now })
        let minute: TimeInterval = 60
        let hour: TimeInterval = 3_600

        func ticket(
            _ title: String, _ status: TicketStatus, _ reason: WaitingReason? = nil, project: String? = nil,
            next: String? = nil, ago: TimeInterval, kept: Bool = false, archived: Bool = false,
            locations: [(Locator, String?)] = []
        ) throws {
            let created = try store.createTicket(NewTicket(
                title: title, status: status, project: project, nextAction: next, pinnedTitle: kept,
                waitingReason: reason, lastActivityAt: now.addingTimeInterval(-ago), kept: kept))
            for (locator, key) in locations {
                try store.addLocation(ticketId: created.id, locator: locator, source: .hook, externalKey: key)
            }
            if archived { try store.patchTicket(id: created.id, TicketPatch(archivedAt: .some(now.addingTimeInterval(-hour)))) }
        }
        func orca(_ tab: String) -> (Locator, String?) {
            (.orcaTerminal(.init(terminalHandle: "term_\(tab)", tabId: tab)), "orca-tab:\(tab)")
        }

        if L10n.current == .ko {
            try ticket("로그인 리다이렉트 무한 반복 오류를 재현하고 원인 찾아 고치기", .waiting, .permission, project: "web-app", next: "셸 명령 실행을 승인해 주세요",
                       ago: 2 * minute, kept: true, locations: [orca("t1")])
            try ticket("결제 모듈 리팩터링 후 환불 흐름 회귀 테스트 보강하기", .waiting, .turnEnd, project: "billing", ago: 12 * minute, locations: [orca("t2")])
            try ticket("간헐적으로 실패하는 CI 잡의 원인 조사와 재시도 정책 정리", .waiting, .stale, project: "ci-tools", ago: 47 * minute,
                       locations: [(.codexThread(.init(threadId: "c1", cwd: "/Users/me/Work/ci-tools")), "codex:c1")])
            try ticket("설정 스키마를 새 버전으로 옮기고 마이그레이션 스크립트 작성", .waiting, .error, project: "web-app", ago: hour,
                       locations: [(.claudeCode(.init(sessionId: "s1", cwd: "/Users/me/Work/web-app")), "claude:s1")])
            try ticket("검색 응답 지연 프로파일링 및 인덱스 캐시 크기 조정 실험", .active, project: "search-platform-experiments", next: "벤치마크 실행이 끝나길 기다리는 중",
                       ago: 5 * minute, kept: true, locations: [orca("t3")])
            try ticket("출시 공지문 초안 작성 (영문 Launch announcement 포함)", .active, project: "ChatGPT", ago: 20 * minute,
                       locations: [(.chatgptChat(.init(chatId: "chat1", url: "https://chatgpt.com/c/chat1")), "chatgpt:chat1")])
            try ticket("재시도 예산(retry budget) RFC 읽고 요약해서 팀에 공유하기", .inbox, ago: 3 * hour,
                       locations: [(.url(.init(url: "https://example.com/rfc")), nil)])
            try ticket("외부 업체 계약서 검토", .blocked, next: "법무팀 회신 대기", ago: 5 * hour, kept: true,
                       locations: [(.claudeChat(.init(chatUuid: "u1", url: "https://claude.ai/chat/u1")), nil)])
            try ticket("신규 입사자 온보딩 문서 최신화", .done, project: "docs", ago: 3 * hour, locations: [orca("t4")])
            try ticket("스파이크: 캐시 무효화 전략 비교", .active, project: "search", ago: 30 * hour, archived: true,
                       locations: [orca("t5")])
            try ticket("CLI 플래그 프로토타입", .waiting, .turnEnd, project: "ci-tools", ago: 52 * hour, archived: true,
                       locations: [(.codexThread(.init(threadId: "c2")), "codex:c2")])
            try ticket("오래된 inbox 항목", .inbox, ago: 100 * hour, archived: true)
        } else {
            try ticket("Reproduce and fix the endless login redirect loop", .waiting, .permission, project: "web-app", next: "Please approve the shell command",
                       ago: 2 * minute, kept: true, locations: [orca("t1")])
            try ticket("Add refund-flow regression tests", .waiting, .turnEnd, project: "billing", ago: 12 * minute, locations: [orca("t2")])
            try ticket("Investigate flaky CI job, fix retry policy", .waiting, .stale, project: "ci-tools", ago: 47 * minute,
                       locations: [(.codexThread(.init(threadId: "c1", cwd: "/Users/me/Work/ci-tools")), "codex:c1")])
            try ticket("Migrate settings schema to the new version", .waiting, .error, project: "web-app", ago: hour,
                       locations: [(.claudeCode(.init(sessionId: "s1", cwd: "/Users/me/Work/web-app")), "claude:s1")])
            try ticket("Profile search latency and experiment with index cache sizes", .active, project: "search-platform-experiments", next: "Waiting for the benchmark run to finish",
                       ago: 5 * minute, kept: true, locations: [orca("t3")])
            try ticket("Draft the launch announcement", .active, project: "ChatGPT", ago: 20 * minute,
                       locations: [(.chatgptChat(.init(chatId: "chat1", url: "https://chatgpt.com/c/chat1")), "chatgpt:chat1")])
            try ticket("Read the retry budget RFC, share a summary", .inbox, ago: 3 * hour,
                       locations: [(.url(.init(url: "https://example.com/rfc")), nil)])
            try ticket("Review the vendor contract", .blocked, next: "Waiting for legal's reply", ago: 5 * hour, kept: true,
                       locations: [(.claudeChat(.init(chatUuid: "u1", url: "https://claude.ai/chat/u1")), nil)])
            try ticket("Update the new-hire onboarding doc", .done, project: "docs", ago: 3 * hour, locations: [orca("t4")])
            try ticket("Spike: compare cache invalidation strategies", .active, project: "search", ago: 30 * hour, archived: true,
                       locations: [orca("t5")])
            try ticket("CLI flag prototype", .waiting, .turnEnd, project: "ci-tools", ago: 52 * hour, archived: true,
                       locations: [(.codexThread(.init(threadId: "c2")), "codex:c2")])
            try ticket("Old inbox item", .inbox, ago: 100 * hour, archived: true)
        }
    }
}
