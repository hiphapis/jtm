import Foundation

public enum AppPaths {
    /// CLI와 같은 규칙: `JTM_DB_PATH`가 있으면 그것, 없으면 `~/Library/Application Support/jtm/jtm.sqlite`.
    public static func databasePath(
        environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()
    ) -> String {
        if let override = environment["JTM_DB_PATH"], !override.isEmpty { return override }
        return home + "/Library/Application Support/jtm/jtm.sqlite"
    }
}
