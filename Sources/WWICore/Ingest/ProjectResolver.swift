import Foundation

/// `cwd`가 속한 git 저장소의 최상위 폴더를 찾는다. Reconciler는 프로세스를 띄우지 않으므로 주입받는다.
public protocol ProjectResolver: Sendable {
    /// 최상위 폴더의 경로. 저장소가 아니면 nil.
    func gitTopLevel(containing cwd: String) -> String?
}

/// `cwd`에서 위로 올라가며 `.git`(폴더, 또는 워크트리의 파일)이 있는 첫 디렉터리를 찾는다. 프로세스를 띄우지 않는다.
public struct FileSystemProjectResolver: ProjectResolver {
    public init() {}

    public func gitTopLevel(containing cwd: String) -> String? {
        var directory = (cwd as NSString).standardizingPath
        guard directory.hasPrefix("/") else { return nil }
        while true {
            if FileManager.default.fileExists(atPath: directory + "/.git") { return directory }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory || parent.isEmpty { return nil }
            directory = parent
        }
    }
}
