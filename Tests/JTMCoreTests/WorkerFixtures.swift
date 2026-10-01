import Foundation

/// 오케스트레이션 워커가 받는 첫 프롬프트의 모양(실측)을 가짜 값으로 만든 것. 실제 handle, ID, 경로는 넣지 않는다.
enum WorkerFixtures {
    /// Codex는 안내문을 그대로 받는다.
    static let preamble = """
        You are working inside Orca, a multi-agent IDE. You are a dispatched worker.
        Your coordinator's terminal handle is: term_00000000-0000-4000-8000-00000000c001
        Your task ID is: task_000000000000

        === CLI COMMANDS ===
        orca orchestration send --from term_00000000-0000-4000-8000-00000000a001 --type worker_done

        === TASK ===
        [P-W] example worker task
        REPO: /Users/me/Work/app
        """

    /// Codex가 받는 프롬프트: 안내문이 그대로 앞에 온다.
    static let codexPrompt = preamble

    /// Claude는 안내문을 붙여넣기 블록으로 감싼다.
    static let claudePrompt = """
        Please carry out this task from my Orca coordinator by following the brief I pasted below.

        <pasted_content id="0001">
        \(preamble)
        </pasted_content id="0001">
        """
}
