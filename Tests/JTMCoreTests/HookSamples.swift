import Foundation
import Testing

/// 실제 Claude Code v2.1.285 / Codex 0.158.0 훅 페이로드의 **모양**(`Tests/Fixtures/hook-payload-samples.jsonl` — 테스트 타깃 밖이라 SwiftPM 리소스 경고가 없다).
/// 한 줄 = `{agent, event, env, payload}`. 값은 전부 가짜다: 경로는 `/Users/me/...`, ID는 새로 만든 UUID, 프롬프트·응답은 `synthetic ...`.
/// Claude 세션 하나와 Codex 세션 하나만 담는다(`PrivacyTests`가 실제 값이 다시 들어오는 것을 막는다).
/// 그 밖의 경우(SessionStart 없이 Stop으로 시작하는 세션 등)는 `syntheticSamples()`의 가짜 이벤트로 채운다.
struct HookSample {
    var agent: String
    var event: String
    var env: [String: String]
    var payload: Data
}

func loadHookSamples() throws -> [HookSample] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/hook-payload-samples.jsonl")
    let text = try String(contentsOf: url, encoding: .utf8)
    return try text.split(separator: "\n").map { line in
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return HookSample(
            agent: object["agent"] as? String ?? "",
            event: object["event"] as? String ?? "",
            env: object["env"] as? [String: String] ?? [:],
            payload: try JSONSerialization.data(withJSONObject: object["payload"] ?? [:]))
    }
}

/// 실측 Codex 샘플의 `transcript_path`가 가리키는 기록 파일은 테스트 기계에 없다(없으면 `UserPromptSubmit`이 내부 작업으로 무시된다).
/// 임시 폴더에 사용자 세션의 `session_meta` 첫 줄만 든 가짜 기록 파일을 만들고 페이로드의 경로를 그쪽으로 바꾼다.
func materializeTranscripts(_ samples: [HookSample], in directory: String) throws -> [HookSample] {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    return try samples.map { sample in
        guard sample.agent == "codex",
              var object = try JSONSerialization.jsonObject(with: sample.payload) as? [String: Any],
              let original = object["transcript_path"] as? String
        else { return sample }
        let path = directory + "/" + (original as NSString).lastPathComponent
        let line = #"{"type":"session_meta","payload":{"source":"cli","thread_source":"user"}}"# + "\n"
        try line.write(toFile: path, atomically: true, encoding: .utf8)
        object["transcript_path"] = path
        var copy = sample
        copy.payload = try JSONSerialization.data(withJSONObject: object)
        return copy
    }
}

extension HookSample {
    var isAgent: Bool { agent == "claude" || agent == "codex" }
}

/// 실측에서 뺀 경우를 채우는 가짜 세션: SessionStart 없이 Stop으로 시작하고, 다른 탭에서 돈다(자리표시자 제목 → 첫 프롬프트).
func syntheticSamples() throws -> [HookSample] {
    let env = [
        "ORCA_TAB_ID": "synthetic-tab-0001", "ORCA_TERMINAL_HANDLE": "term_synthetic-0001",
        "ORCA_WORKTREE_ID": "synthetic-wt::/Users/me/Work/synthetic-project",
    ]
    func sample(_ event: String, prompt: String? = nil, extra: [String: Any] = [:]) throws -> HookSample {
        var payload: [String: Any] = [
            "hook_event_name": event, "session_id": "synthetic-session-0001", "cwd": "/Users/me/Work/synthetic-project",
        ]
        if let prompt { payload["prompt"] = prompt }
        payload.merge(extra) { $1 }
        return HookSample(agent: "claude", event: event, env: env, payload: try JSONSerialization.data(withJSONObject: payload))
    }
    return [
        try sample("Stop"),
        try sample("Notification", extra: ["notification_type": "idle_prompt"]),
        try sample("UserPromptSubmit", prompt: "synthetic prompt"),
        try sample("Stop"),
        try sample("Notification", extra: ["notification_type": "idle_prompt"]),
    ]
}
