import Foundation

public enum OrcaCLI {
    public static let fallbackPath = "/usr/local/bin/orca"

    /// `ORCA_CLI_COMMAND`(실행 파일 경로) → PATH의 `orca` → `/usr/local/bin/orca` 순으로 찾는다. 없으면 nil.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let override = environment["ORCA_CLI_COMMAND"], !override.isEmpty { return override }
        let onPath = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/orca" }
            .first(where: isExecutable)
        if let onPath { return onPath }
        return isExecutable(fallbackPath) ? fallbackPath : nil
    }
}
