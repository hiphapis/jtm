import Foundation

/// 데이터베이스 파일 위치를 정하는 규칙의 단일 정의(CLI와 메뉴바 앱이 함께 쓴다).
/// `WWI_DB_PATH`가 있으면 그것, 없으면 예전 이름 `JTM_DB_PATH`(훅은 사용자의 환경 변수를 그대로 이어받으므로 한동안 받아 준다),
/// 둘 다 없으면 `~/Library/Application Support/jtm/jtm.sqlite`다. 데이터 폴더와 파일 이름은 0.1.x부터 그대로다: 보이지 않게 저장되는 이름이라 바꾸지 않는다.
public enum DatabasePath {
    public static let environmentKey = "WWI_DB_PATH"
    public static let legacyEnvironmentKey = "JTM_DB_PATH"

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()
    ) -> String {
        for key in [environmentKey, legacyEnvironmentKey] {
            if let value = environment[key], !value.isEmpty { return value }
        }
        return home + "/Library/Application Support/jtm/jtm.sqlite"
    }
}
