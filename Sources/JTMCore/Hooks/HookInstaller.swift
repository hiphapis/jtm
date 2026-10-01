import Foundation

public struct HookFileError: Error, CustomStringConvertible {
    public var description: String
    init(_ description: String) { self.description = description }
}

/// 설정 파일 하나에 대한 계획(읽기만 한 결과)과 적용 결과.
public struct HookFilePlan: Sendable {
    public enum Operation: Sendable { case install, uninstall }

    public var agent: HookAgent
    /// 사용자가 지정한(또는 기본) 경로.
    public var path: String
    /// 심볼릭 링크를 따라간 실제 쓰기 대상.
    public var resolvedPath: String
    public var existed: Bool
    public var before: String
    public var after: String
    public var changes: [HookChange]
    /// 계획을 세운 시점의 파일 바이트. 적용 직전에 바뀌었는지 확인하는 데 쓴다.
    fileprivate var originalData: Data?
    /// `apply` 뒤에 채워진다.
    public var backupPath: String?
    public var written = false

    public var isNoop: Bool { changes.isEmpty }
}

public enum HookInstaller {
    /// 파일을 읽어 변경 계획을 만든다. 아무것도 쓰지 않는다. 파일이 없으면 설치는 새로 만들 계획을, 제거는 빈 계획을 낸다.
    public static func plan(
        _ operation: HookFilePlan.Operation, agent: HookAgent, path: String, jtmPath: String
    ) throws -> HookFilePlan {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let resolved = resolveSymlinks(absolute)
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        let existed = fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory)
        if existed, isDirectory.boolValue { throw HookFileError("\(path): 파일이 아니라 디렉터리다") }

        var data: Data?
        var config = HookConfig()
        if existed {
            do { data = try Data(contentsOf: URL(fileURLWithPath: resolved)) } catch {
                throw HookFileError("\(path): 읽을 수 없다 (\(error.localizedDescription))")
            }
            do { config = try HookConfig.parse(data!) } catch {
                throw HookFileError("\(path): \(error)")
            }
        }

        let before = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let changes: [HookChange]
        do {
            switch operation {
            case .install: changes = try config.install(agent: agent, jtmPath: jtmPath)
            case .uninstall: changes = try config.uninstall(agent: agent)
            }
        } catch let error as HookConfigError {
            throw HookFileError("\(path): \(error)")
        }

        return HookFilePlan(
            agent: agent, path: absolute, resolvedPath: resolved, existed: existed,
            before: before, after: changes.isEmpty ? before : config.render(), changes: changes,
            originalData: data)
    }

    /// 백업 → 임시 파일 → rename 순서로 쓴다. 변경이 없으면 아무것도 하지 않는다(백업도 만들지 않는다).
    /// `beforeRename`은 임시 파일을 다 쓴 뒤, 마지막 비교 직전에 불린다(테스트가 그 사이의 경합을 재현하는 자리).
    public static func apply(_ plan: inout HookFilePlan, now: Date = Date(), beforeRename: () -> Void = {}) throws {
        guard !plan.isNoop else { return }
        let fileManager = FileManager.default
        let target = URL(fileURLWithPath: plan.resolvedPath)
        let directory = target.deletingLastPathComponent()

        // 계획 뒤에 다른 프로세스(Orca 등)가 파일을 바꿨다면 덮어쓰지 않는다.
        try ensureUnchanged(plan)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var permissions: NSNumber = 0o644
        if plan.existed {
            if let attributes = try? fileManager.attributesOfItem(atPath: plan.resolvedPath),
               let mode = attributes[.posixPermissions] as? NSNumber {
                permissions = mode
            }
            let backup = uniqueBackupPath(for: plan.resolvedPath, now: now)
            do { try fileManager.copyItem(atPath: plan.resolvedPath, toPath: backup) } catch {
                throw HookFileError("\(plan.path): 백업을 만들 수 없다 (\(error.localizedDescription))")
            }
            plan.backupPath = backup
        }

        let temp = directory.appendingPathComponent(".\(target.lastPathComponent).jtm-tmp-\(UUID().uuidString)")
        func discard(_ error: Error) -> Error {
            try? fileManager.removeItem(at: temp)
            return error
        }
        do { try writeExclusively(Data(plan.after.utf8), to: temp.path, mode: permissions.uint16Value) } catch {
            throw discard(HookFileError("\(plan.path): 쓰지 못했다 (\(error))"))
        }
        beforeRename()
        // 비교와 rename 사이의 창을 좁힌다: 임시 파일을 다 쓴 지금, 원본이 그대로인지 한 번 더 확인한다.
        // 바뀌었다면 아무것도 바꾸지 않은 것이므로 방금 만든 백업도 지운다.
        do { try ensureUnchanged(plan) } catch {
            if let backup = plan.backupPath {
                try? fileManager.removeItem(atPath: backup)
                plan.backupPath = nil
            }
            throw discard(error)
        }
        guard rename(temp.path, target.path) == 0 else {
            throw discard(HookFileError("\(plan.path): 쓰지 못했다 (rename 실패: \(String(cString: strerror(errno))))"))
        }
        plan.written = true
    }

    /// 계획을 세운 뒤 대상 파일이 바뀌지 않았는지(없던 파일이 생기지 않았는지) 확인한다.
    private static func ensureUnchanged(_ plan: HookFilePlan) throws {
        if plan.existed {
            let current = try? Data(contentsOf: URL(fileURLWithPath: plan.resolvedPath))
            guard current == plan.originalData else {
                throw HookFileError("\(plan.path): 읽은 뒤 파일이 바뀌었다. 다시 실행해 달라")
            }
        } else if FileManager.default.fileExists(atPath: plan.resolvedPath) {
            throw HookFileError("\(plan.path): 확인한 뒤 파일이 새로 생겼다. 다시 실행해 달라")
        }
    }

    /// 임시 파일은 처음부터 원본 권한의 소유자 비트만으로 만들어(그룹/기타 접근 없음) 내용을 쓴 뒤 정확히 원본 권한으로 맞춘다.
    /// 만든 다음에 `chmod`하면 그 사이 다른 사용자가 읽을 수 있다(`env`에 토큰이 든 `settings.json` 등).
    private static func writeExclusively(_ data: Data, to path: String, mode: UInt16) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode) & 0o600)
        guard descriptor >= 0 else { throw HookFileError("임시 파일을 만들 수 없다: \(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        var offset = 0
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw HookFileError("쓰기 실패: \(String(cString: strerror(errno)))")
                }
                offset += written
            }
        }
        guard fchmod(descriptor, mode_t(mode)) == 0 else {
            throw HookFileError("권한 설정 실패: \(String(cString: strerror(errno)))")
        }
    }

    /// `<file>.jtm-backup-YYYYMMDD-HHMMSS`. 같은 초에 이미 있으면 `-1`, `-2`…를 붙인다.
    public static func uniqueBackupPath(for path: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(path).jtm-backup-\(formatter.string(from: now))"
        var candidate = base
        var counter = 0
        while FileManager.default.fileExists(atPath: candidate) {
            counter += 1
            candidate = "\(base)-\(counter)"
        }
        return candidate
    }

    /// 경로 자체가 심볼릭 링크면 가리키는 실제 파일 경로로 바꾼다(dotfiles 저장소로 링크한 설정을 링크째 덮어쓰지 않으려고).
    /// 대상이 아직 없는 링크는 링크 값을 따라간다.
    public static func resolveSymlinks(_ path: String) -> String {
        let fileManager = FileManager.default
        var current = path
        for _ in 0..<16 {
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: current) else { return current }
            let parent = (current as NSString).deletingLastPathComponent
            current = URL(fileURLWithPath: destination, relativeTo: URL(fileURLWithPath: parent, isDirectory: true))
                .standardizedFileURL.path
        }
        return current
    }
}
