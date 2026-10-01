/// 훅을 설치한 뒤 사용자에게 보여 줄 안내. CLI(`jtm hooks install`)와 메뉴바 앱의 설정 카드가 같은 문구를 쓴다.
public enum HookNotices {
    /// Codex는 새로 추가되거나 바뀐 훅을 사용자가 신뢰해야 실행한다. 한 줄이 한 항목이다(앞의 두 줄이 요지).
    public static let codexTrust: [String] = [
        "Codex 안내: 다음에 Codex를 실행하면 새로 추가된 훅을 검토하라는 화면(\"N hooks are new or changed\")이 뜬다.",
        "  → 내용을 확인하고 \"Trust all\"을 선택해야 jtm 훅이 실행된다. 훅 내용이 바뀌면(예: jtm 경로 변경) 다시 검토해야 한다.",
        "  → 프로젝트 폴더에서는 처음 한 번 폴더 신뢰(\"Trust this folder?\")도 묻는다.",
        "  → 신뢰 기록은 ~/.codex/config.toml의 [hooks.state.\"<hooks.json 경로>:<이벤트>:<그룹>:<훅>\"] (trusted_hash)에 저장된다.",
    ]
}
