import Foundation

/// 전역 단축키 등록 결과. 푸터에 현재 단축키와, 등록하지 못했으면 그 이유를 보여준다.
public enum HotKeyStatus: Equatable, Sendable {
    case registered(label: String)
    /// `code`는 Carbon `OSStatus`.
    case failed(label: String, code: Int32)

    /// Carbon `eventHotKeyExistsErr`: 다른 프로세스가 같은 조합을 독점(exclusive)으로 등록했다.
    public static let existsError: Int32 = -9878

    public var label: String {
        switch self {
        case .registered(let label), .failed(let label, _): label
        }
    }

    /// 등록하지 못했을 때의 안내. 정상이면 nil.
    public var problem: String? {
        switch self {
        case .registered: nil
        case .failed(let label, let code):
            code == Self.existsError
                ? "\(label) 단축키를 다른 앱이 이미 쓰고 있어요"
                : "\(label) 단축키를 등록하지 못했어요 (코드 \(code))"
        }
    }
}
