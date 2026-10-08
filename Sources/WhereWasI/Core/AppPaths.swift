import Foundation
import WWICore

public enum AppPaths {
    /// CLI와 같은 규칙(`DatabasePath`): `WWI_DB_PATH`, 없으면 예전 `JTM_DB_PATH`, 없으면 `~/Library/Application Support/jtm/jtm.sqlite`.
    public static func databasePath(
        environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()
    ) -> String {
        DatabasePath.resolve(environment: environment, home: home)
    }
}
