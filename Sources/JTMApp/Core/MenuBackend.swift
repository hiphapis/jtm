import Foundation
import JTMCore

/// `go` 결과. 성공이고 클립보드 복사가 아니면 팝오버를 닫고, 아니면 행 아래에 메시지를 보여준다.
public struct GoOutcome: Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var copiedToClipboard: Bool

    public init(ok: Bool, message: String, copiedToClipboard: Bool = false) {
        self.ok = ok
        self.message = message
        self.copiedToClipboard = copiedToClipboard
    }
}

/// 컨트롤러가 DB와 리졸버에 접근하는 창구(테스트에서는 가짜로 바꾼다).
public protocol MenuBackend: Sendable {
    func load(now: Date) async throws -> [TicketListing]
    func setStatus(id: Int64, _ status: TicketStatus) async throws
    func setNextAction(id: Int64, _ text: String?) async throws
    func setTitle(id: Int64, _ title: String) async throws
    func go(id: Int64) async -> GoOutcome
    /// ⭐ 유지 토글. 유지로 만들면 보관도 풀린다.
    func setKept(id: Int64, _ kept: Bool) async throws
    /// 🗑 무시: 티켓을 지우고 세션 키를 무시 목록에 올린다(되돌릴 수 없다 — 되돌리기 창은 컨트롤러가 이 호출을 미뤄서 만든다).
    func ignore(id: Int64) async throws
    /// 보관함에서 되살린다(보관 해제 + 유지).
    func restore(id: Int64) async throws
    /// 24시간 활동이 없는 유지 안 한 티켓을 보관한다. 보관한 수.
    @discardableResult func archiveStale(now: Date) async throws -> Int
}

/// 기본 구현은 아무것도 하지 않는다(이 메서드들을 모르는 가짜 백엔드가 그대로 컴파일되도록).
public extension MenuBackend {
    func setKept(id: Int64, _ kept: Bool) async throws {}
    func ignore(id: Int64) async throws {}
    func restore(id: Int64) async throws {}
    @discardableResult func archiveStale(now: Date) async throws -> Int { 0 }
}

/// 실제 구현. `Store`는 스레드 간에 공유하지 않으므로 큐마다 자기 연결을 가진다.
/// 읽기는 읽기 전용 연결(쓰기 잠금 없음, 짧은 스냅샷 트랜잭션)이라 훅의 쓰기를 막지 않는다.
/// 쓰기는 한 문장짜리 `patchTicket`이고, 이동(`go`)은 최대 십여 초 걸릴 수 있어 전용 큐에 둔다.
public final class DatabaseBackend: MenuBackend, @unchecked Sendable {
    private let path: String
    private let makeResolver: @Sendable () -> Resolver
    private let readQueue = DispatchQueue(label: "jtm.app.db-read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "jtm.app.db-write", qos: .userInitiated)
    private let goQueue = DispatchQueue(label: "jtm.app.go", qos: .userInitiated)
    // 각각 자기 큐에서만 만진다.
    private var reader: Store?
    private var writer: Store?

    public init(
        databasePath: String,
        makeResolver: @escaping @Sendable () -> Resolver = {
            Resolver(runner: ProcessRunner(), orcaCommand: OrcaCLI.locate())
        }
    ) {
        self.path = databasePath
        self.makeResolver = makeResolver
    }

    private func run<T: Sendable>(
        on queue: DispatchQueue, _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    // MARK: Read

    public func load(now: Date) async throws -> [TicketListing] {
        try await run(on: readQueue) {
            func read() throws -> [TicketListing] {
                try self.readStore().menuListing(doneSince: now.addingTimeInterval(-MenuState.doneWindow))
            }
            do { return try read() } catch {
                // DB 파일이 지워지고 새로 만들어지면(초기화, 백업 복원) 쥐고 있던 연결이 죽은 파일을 본다.
                // 연결을 버리고 한 번 더 읽는다. 그래도 실패하면 그 오류를 낸다(다음에는 새로 연다).
                self.reader = nil
                do { return try read() } catch {
                    self.reader = nil
                    throw error
                }
            }
        }
    }

    private func readStore() throws -> Store {
        if let reader { return reader }
        let store: Store
        do {
            store = try Store(readOnlyPath: path, onWarning: { _ in })
        } catch {
            // 파일이 없거나 아직 마이그레이션 전이다: CLI처럼 쓰기 가능한 Store가 한 번 열어서 만들고 맞춘 뒤 다시 연다.
            _ = try Store(path: path, onWarning: { _ in })
            store = try Store(readOnlyPath: path, onWarning: { _ in })
        }
        reader = store
        return store
    }

    // MARK: Write

    /// 쓰기 큐에서 `Store` 하나를 재사용해 한 번의 쓰기를 한다. 없는 티켓 오류가 아니면 연결을 버린다(다음에 새로 연다).
    private func write<T: Sendable>(_ work: @escaping @Sendable (Store) throws -> T) async throws -> T {
        try await run(on: writeQueue) {
            if self.writer == nil { self.writer = try Store(path: self.path, onWarning: { _ in }) }
            do { return try work(self.writer!) } catch {
                if case StoreError.ticketNotFound = error { throw error }
                self.writer = nil
                throw error
            }
        }
    }

    /// 사용자가 직접 한 수정이다: 제목/next_action 편집과 상태 변경(done 제외)은 티켓을 유지(⭐)로 만든다.
    private func patch(id: Int64, _ patch: TicketPatch) async throws {
        try await write { _ = try $0.patchTicketAsUser(id: id, patch) }
    }

    public func setStatus(id: Int64, _ status: TicketStatus) async throws {
        try await patch(id: id, TicketPatch(status: status))
    }

    public func setNextAction(id: Int64, _ text: String?) async throws {
        let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await patch(id: id, TicketPatch(nextAction: .some(cleaned?.isEmpty == false ? cleaned : nil)))
    }

    /// 직접 고친 제목은 고정된다(자동 갱신이 덮어쓰지 않는다).
    public func setTitle(id: Int64, _ title: String) async throws {
        try await patch(id: id, TicketPatch(title: title.trimmingCharacters(in: .whitespacesAndNewlines), pinnedTitle: true))
    }

    public func setKept(id: Int64, _ kept: Bool) async throws {
        try await write { _ = try $0.setKept(id: id, kept) }
    }

    public func ignore(id: Int64) async throws {
        try await write { _ = try $0.ignoreTicket(id: id) }
    }

    public func restore(id: Int64) async throws {
        try await write { _ = try $0.restoreTicket(id: id) }
    }

    @discardableResult
    public func archiveStale(now: Date) async throws -> Int {
        try await write { try $0.archiveStale(now: now) }
    }

    // MARK: Go

    public func go(id: Int64) async -> GoOutcome {
        do {
            return try await run(on: goQueue) {
                let store = try Store(path: self.path, onWarning: { _ in })
                let result = try self.makeResolver().go(ticketId: id, store: store)
                return GoOutcome(ok: result.ok, message: result.message, copiedToClipboard: result.copiedToClipboard)
            }
        } catch ResolveError.noLocations {
            return GoOutcome(ok: false, message: L10n.string(.noDestination))
        } catch {
            return GoOutcome(ok: false, message: "\(error)")
        }
    }
}
