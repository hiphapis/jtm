import Foundation

/// Codex 기록 파일(`rollout-*.jsonl`) 첫 줄 `session_meta`에서 읽은, 내부 작업을 가려내는 데 쓰는 값
/// (`docs/01-product/auto-capture.md`의 "Codex 내부 작업은 수집하지 않는다").
/// ```
/// {"type":"session_meta","payload":{"source":"cli"|"vscode"|{"subagent":{…}},"thread_source":"user"|…,…}}
/// ```
public struct CodexSessionMeta: Equatable, Sendable {
    /// `payload.source`. 문자열이면 그 값, 객체(`{"subagent":{…}}`)면 키들을 이어 붙인 것이다(`subagent` 검사용).
    public var source: String?
    public var threadSource: String?

    public init(source: String? = nil, threadSource: String? = nil) {
        self.source = source
        self.threadSource = threadSource
    }

    public static let guardianThreadSource = "guardian_review"
    /// `ignored_sessions`에 남기는 사유.
    public static let internalReason = "codex-internal"
    /// 기록 파일이 끝내 안 생겨서(`Reconciler.missingRolloutGrace`) 일회성 내부 작업으로 본 세션의 사유. 확실한 증거(하위 에이전트,
    /// guardian 검토)가 있는 `codex-internal`과 구분한다: 이 사유는 나중에 파일이 생기면 스스로 풀린다.
    public static let noFileReason = "codex-internal-nofile"

    /// 사용자 세션이 아니라 Codex가 스스로 돌린 하위/검토 작업인가. `user`, `chatgpt_handoff`, 값 없음은 사용자 세션으로 본다.
    public var isInternal: Bool {
        if let source, source.lowercased().contains("subagent") { return true }
        return threadSource == Self.guardianThreadSource
    }

    /// 첫 줄(JSON 한 줄)을 해석한다. `session_meta`가 아니거나 깨졌으면 nil(알 수 없음 → 수집한다).
    static func parse(line: Data) -> CodexSessionMeta? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any]
        else { return nil }
        let source: String?
        switch payload["source"] {
        case let text as String: source = text
        case let nested as [String: Any]: source = nested.keys.sorted().joined(separator: ",")
        default: source = nil
        }
        return CodexSessionMeta(source: source, threadSource: payload["thread_source"] as? String)
    }
}

/// 기록 파일을 읽은 결과.
public enum CodexTranscriptProbe: Equatable, Sendable {
    /// 파일이 없다(아직 안 만들어졌거나 일회성 내부 작업이라 만들어지지 않았다).
    case missing
    /// 파일은 있지만 첫 줄을 해석하지 못했다(빈 파일, 깨진 줄, 알 수 없는 모양). 보수적으로 수집한다.
    case unknown
    case meta(CodexSessionMeta)
}

/// `transcript_path`의 첫 줄을 읽는 창구. `Reconciler`가 프로세스도 파일도 직접 만지지 않도록 주입받는다(테스트는 가짜로 바꾼다).
public protocol CodexTranscriptReading: Sendable {
    func probe(path: String) -> CodexTranscriptProbe
}

/// 파일의 첫 줄만(최대 `lineLimit` 바이트) 읽는다. 프로세스를 띄우지 않는다.
/// 일반 파일이 아니면(FIFO, 장치) 읽지 않고 `unknown`이다: 훅 입력의 경로라서 `O_NONBLOCK`으로 열어 막히지 않게 한다.
public struct FileCodexTranscriptReader: CodexTranscriptReading {
    public static let lineLimit = 64 * 1024

    public init() {}

    public func probe(path: String) -> CodexTranscriptProbe {
        guard path.hasPrefix("/") else { return .unknown }
        let descriptor = open(path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { return errno == ENOENT || errno == ENOTDIR ? .missing : .unknown }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .unknown }

        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        while line.count < Self.lineLimit {
            let count = read(descriptor, &buffer, min(buffer.count, Self.lineLimit - line.count))
            if count < 0 { if errno == EINTR { continue }; break }
            if count == 0 { break }
            if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
                line.append(contentsOf: buffer[0..<newline])
                return CodexSessionMeta.parse(line: line).map(CodexTranscriptProbe.meta) ?? .unknown
            }
            line.append(contentsOf: buffer[0..<count])
        }
        // 줄바꿈 없이 끝났다(마지막 줄이 아직 쓰이는 중이거나 한도 초과): 한도 안에서 JSON이 완성돼 있으면 쓴다.
        return CodexSessionMeta.parse(line: line).map(CodexTranscriptProbe.meta) ?? .unknown
    }
}
