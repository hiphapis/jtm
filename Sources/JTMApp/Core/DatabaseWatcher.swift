import Foundation
import JTMCore

/// DB 변경 감시. 훅이 CLI로 쓰므로 앱은 파일이 바뀌는 것을 알아채야 한다.
/// 1) DispatchSource로 DB 파일, `-wal`, 그 폴더를 감시한다(WAL 쓰기는 본 파일의 mtime을 바꾸지 않으므로 `-wal`이 핵심이고,
///    마지막 연결이 닫히면 `-wal`이 지워졌다 다시 생기므로 폴더도 보고 사라지면 다시 건다).
/// 2) 놓칠 때를 대비해 `pollInterval`마다 `PRAGMA data_version`(다른 커넥션의 커밋에만 바뀌는 값)을 확인한다.
/// 이벤트는 후행 디바운스로 묶는다: 마지막 이벤트 뒤 `debounce`가 지나면 `onChange`를 부르되, 이벤트가 계속 이어져도
/// 첫 이벤트 뒤 `maxWait`를 넘기지 않는다(훅 폭주 중에도 초당 한 번쯤은 갱신된다).
public final class DatabaseWatcher: @unchecked Sendable {
    public struct Options: Sendable {
        public var pollInterval: TimeInterval = 2
        /// 마지막 이벤트 뒤 이만큼 조용하면 알린다.
        public var debounce: TimeInterval = 0.25
        /// 이벤트가 끊기지 않아도 첫 이벤트 뒤 이 시간 안에는 알린다.
        public var maxWait: TimeInterval = 1
        /// 팝오버가 닫혀 있을 때(배지만 필요할 때)의 값. 한 번의 변경은 `idleDebounce` 만에 알리고(1초 이내), 폭주 중에는
        /// `idleMaxWait`에 한 번만 알린다.
        public var idleDebounce: TimeInterval = 0.4
        public var idleMaxWait: TimeInterval = 2
        /// false면 폴링만 쓴다(폴링 경로 검증용).
        public var useFileEvents = true
        public init() {}
    }

    private let path: String
    private let options: Options
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "jtm.app.db-watch", qos: .userInitiated)

    // 아래는 모두 `queue`에서만 만진다.
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var timer: DispatchSourceTimer?
    private var pendingItem: DispatchWorkItem?
    private var firstPendingAt: TimeInterval?
    private var probe: Store?
    private var lastVersion: Int64?
    private var lastExists: Bool?
    private var stopped = false
    private var active = false

    public init(path: String, options: Options = Options(), onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.options = options
        self.onChange = onChange
    }

    public func start() {
        queue.async {
            self.stopped = false
            self.arm()
            self.checkVersion(notify: false)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + self.options.pollInterval, repeating: self.options.pollInterval,
                leeway: .milliseconds(Int(self.options.pollInterval * 250)))
            timer.setEventHandler { [weak self] in
                self?.arm()
                self?.checkVersion(notify: true)
            }
            timer.resume()
            self.timer = timer
        }
    }

    /// 팝오버가 열려 있으면 true(빠른 디바운스), 닫혀 있으면 false. 이미 대기 중인 알림은 그대로 둔다.
    public func setActive(_ active: Bool) {
        queue.async { self.active = active }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.pendingItem?.cancel()
            self.pendingItem = nil
            self.firstPendingAt = nil
            self.timer?.cancel()
            self.timer = nil
            for source in self.sources.values { source.cancel() }
            self.sources.removeAll()
            self.probe = nil
        }
    }

    // MARK: File events

    private var watchedPaths: [String] {
        let directory = (path as NSString).deletingLastPathComponent
        return [path, path + "-wal"] + (directory.isEmpty ? [] : [directory])
    }

    /// 아직 걸리지 않은 경로(파일이 아직 없었거나 지워졌던 것)에 감시를 건다.
    private func arm() {
        guard options.useFileEvents, !stopped else { return }
        for watched in watchedPaths where sources[watched] == nil {
            let descriptor = open(watched, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: queue)
            source.setEventHandler { [weak self] in self?.fired(watched) }
            source.setCancelHandler { close(descriptor) }
            sources[watched] = source
            source.resume()
        }
    }

    private func fired(_ watched: String) {
        guard let source = sources[watched] else { return }
        if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
            // 파일이 지워졌거나 바뀌었다: 이 fd는 죽은 inode를 본다. 닫고 곧 다시 건다.
            source.cancel()
            sources[watched] = nil
            queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.arm() }
        }
        // 폴더 이벤트는 `-wal`이나 DB 파일이 (다시) 생겼다는 신호일 수 있다: 아직 안 걸린 것을 지금 건다.
        arm()
        schedule()
    }

    // MARK: Poll

    private func checkVersion(notify: Bool) {
        let exists = FileManager.default.fileExists(atPath: path)
        var version: Int64?
        if exists {
            if probe == nil { probe = try? Store(readOnlyPath: path, onWarning: { _ in }) }
            do { version = try probe?.dataVersion() } catch { probe = nil }
        } else {
            probe = nil
        }
        let changed = version != lastVersion || exists != lastExists
        lastVersion = version
        lastExists = exists
        if notify, changed { schedule() }
    }

    // MARK: Debounce

    /// 후행 디바운스의 계산(순수 함수: 시계도 큐도 없다): 이벤트가 `now`에 왔을 때 알릴 시각과 이 묶음의 첫 이벤트 시각.
    /// 마지막 이벤트 뒤 `debounce`가 지나면 알리되, 첫 이벤트(`firstPending`, 없으면 지금) 뒤 `maxWait`를 넘기지 않는다.
    /// 시각은 모두 같은 단조 시계의 초 단위다.
    public static func debounceDeadline(
        now: TimeInterval, firstPending: TimeInterval?, debounce: TimeInterval, maxWait: TimeInterval
    ) -> (deadline: TimeInterval, firstPending: TimeInterval) {
        let first = firstPending ?? now
        return (min(now + max(debounce, 0), first + max(maxWait, 0)), first)
    }

    private func schedule() {
        guard !stopped else { return }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        let plan = Self.debounceDeadline(
            now: now, firstPending: firstPendingAt,
            debounce: active ? options.debounce : options.idleDebounce,
            maxWait: active ? options.maxWait : options.idleMaxWait)
        firstPendingAt = plan.firstPending
        let deadline = DispatchTime(uptimeNanoseconds: UInt64(max(plan.deadline, 0) * 1e9))
        pendingItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.pendingItem = nil
            self.firstPendingAt = nil
            self.onChange()
        }
        pendingItem = item
        queue.asyncAfter(deadline: deadline, execute: item)
    }
}
