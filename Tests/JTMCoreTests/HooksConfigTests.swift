import Foundation
import Testing
@testable import JTMCore

private let jtm = "/opt/jtm/bin/jtm"

private func parse(_ text: String) throws -> HookConfig {
    try HookConfig.parse(Data(text.utf8))
}

private func groups(_ config: HookConfig, _ event: String) -> [JSONValue] {
    config.document.root["hooks"]?[event]?.arrayValue ?? []
}

private func json(_ text: String) throws -> JSONValue {
    try JSONDocument.parse(Data(text.utf8)).root
}

private func managedGroup(agent: HookAgent, path: String = jtm) throws -> JSONValue {
    try json("""
    {"hooks":[{"type":"command","command":\(JSONString(HookCommandFormat.command(agent: agent, jtmPath: path)).literal),"timeout":5}]}
    """)
}

// MARK: JSON 계층

@Suite struct HookJSONTests {
    @Test func realShapedFixturesRoundTripByteForByte() throws {
        for text in [HooksFixtures.claudeSettings, HooksFixtures.codexHooks] {
            #expect(try parse(text).render() == text)
        }
    }

    @Test func preservesKeyOrderAndNumberSpellingAndEscapes() throws {
        let text = #"""
        {
          "z": 1.50,
          "a": 12345678901234567890,
          "s": "a\/b é 😀",
          "e": {},
          "l": []
        }

        """#
        let config = try parse(text)
        #expect(config.render() == text)
        #expect(config.document.root["s"]?.stringValue == "a/b é 😀")
    }

    @Test func detectsIndentAndTrailingNewline() throws {
        let fourSpaces = "{\n    \"a\": {\n        \"b\": 1\n    }\n}"
        #expect(try parse(fourSpaces).render() == fourSpaces)
        let tabs = "{\n\t\"a\": [\n\t\t1\n\t]\n}\n"
        #expect(try parse(tabs).render() == tabs)
    }

    @Test func emptyInputIsAnEmptyObject() throws {
        #expect(try HookConfig.parse(Data()).document.root == .object([]))
        #expect(try HookConfig.parse(Data("  \n".utf8)).document.root == .object([]))
    }

    @Test func reportsLineAndColumnOfSyntaxErrors() throws {
        let error = #expect(throws: JSONParseError.self) { try HookConfig.parse(Data("{\n  \"a\": 1,\n}\n".utf8)) }
        #expect(error?.line == 3)
        #expect(throws: JSONParseError.self) { try HookConfig.parse(Data("{\"a\": tru}".utf8)) }
        #expect(throws: JSONParseError.self) { try HookConfig.parse(Data("{\"a\": 1} x".utf8)) }
        #expect(throws: JSONParseError.self) { try HookConfig.parse(Data("{\"a\": \"unterminated}".utf8)) }
    }

    @Test func rejectsNonObjectRoot() {
        #expect(throws: HookConfigError.rootNotObject) { try HookConfig.parse(Data("[1]".utf8)) }
    }
}

// MARK: 명령 형식

@Suite struct HookCommandFormatTests {
    @Test func buildsQuotedCommandWithMarker() {
        #expect(HookCommandFormat.command(agent: .claude, jtmPath: "/a/jtm") == "'/a/jtm' ingest claude # jtm-managed")
        #expect(HookCommandFormat.command(agent: .codex, jtmPath: "/my dir/it's/jtm")
            == #"'/my dir/it'\''s/jtm' ingest codex # jtm-managed"#)
    }

    @Test func extractsPathFromQuotedCommand() {
        for path in ["/a/jtm", "/my dir/it's/jtm", "/opt/jtm/bin/jtm"] {
            let command = HookCommandFormat.command(agent: .claude, jtmPath: path)
            #expect(HookCommandFormat.jtmPath(in: command) == path)
        }
    }

    @Test func recognizesOnlyOurOwnEntries() {
        let ours = HookCommandFormat.command(agent: .claude, jtmPath: "/x/jtm")
        #expect(HookCommandFormat.isManaged(ours, agent: .claude))
        #expect(!HookCommandFormat.isManaged(ours, agent: .codex))
        // 표식이 없으면 남의 항목이다(사용자가 직접 jtm ingest를 걸어 둔 경우).
        #expect(!HookCommandFormat.isManaged("'/x/jtm' ingest claude", agent: .claude))
        #expect(!HookCommandFormat.isManaged("echo hi # jtm-managed", agent: .claude))
        // 상대 경로는 우리가 만든 형식이 아니다.
        #expect(!HookCommandFormat.isManaged("jtm ingest claude # jtm-managed", agent: .claude))
    }

    @Test func rejectsRelativeOrControlCharacterPaths() throws {
        var config = HookConfig()
        #expect(throws: HookConfigError.invalidJTMPath("jtm")) { try config.install(agent: .claude, jtmPath: "jtm") }
        #expect(throws: HookConfigError.self) { try config.install(agent: .claude, jtmPath: "/a\n/jtm") }
    }

    @Test func eventListsMatchTheDesign() {
        #expect(HookAgent.claude.events == [
            "SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "SessionEnd", "StopFailure", "PostToolUse"])
        #expect(HookAgent.codex.events == ["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "PostToolUse"])
        #expect(HookAgent.claude.defaultPath(home: "/h") == "/h/.claude/settings.json")
        #expect(HookAgent.codex.defaultPath(home: "/h") == "/h/.codex/hooks.json")
    }
}

// MARK: 설치 / 제거 / 상태

@Suite struct HookConfigTests {
    @Test func installAppendsOneGroupPerEventAndLeavesExistingGroupsUntouched() throws {
        let original = try parse(HooksFixtures.claudeSettings)
        var config = original
        let changes = try config.install(agent: .claude, jtmPath: jtm)

        #expect(changes.map(\.event) == HookAgent.claude.events)
        #expect(changes.allSatisfy { $0.kind == .add })

        let expected = try managedGroup(agent: .claude)
        for event in HookAgent.claude.events {
            let before = groups(original, event)
            let after = groups(config, event)
            #expect(after.count == before.count + 1)
            #expect(Array(after.dropLast()) == before, "\(event): 기존 그룹의 내용과 순서가 그대로여야 한다")
            #expect(after.last == expected)
        }
        // 설치 대상이 아닌 이벤트와 다른 최상위 키는 손대지 않는다.
        for event in ["Notification", "PreToolUse"] {
            #expect(groups(config, event) == groups(original, event))
        }
        for key in ["env", "statusLine", "enabledPlugins", "language", "ratio", "big", "escaped", "emptyObject", "emptyArray", "nested", "model"] {
            #expect(config.document.root[key] == original.document.root[key], "\(key)")
        }
        let keysAfter = (config.document.root.objectValue ?? []).map { $0.key.value }
        let keysBefore = (original.document.root.objectValue ?? []).map { $0.key.value }
        #expect(keysAfter == keysBefore, "최상위 키 순서는 그대로(hooks는 원래 있던 자리)")
    }

    @Test func installCodexUsesItsOwnEventsAndCommand() throws {
        var config = try parse(HooksFixtures.codexHooks)
        let changes = try config.install(agent: .codex, jtmPath: jtm)
        #expect(changes.map(\.event) == HookAgent.codex.events)
        for event in HookAgent.codex.events {
            #expect(groups(config, event).last == (try managedGroup(agent: .codex)))
        }
        // Orca가 관리하는 다른 이벤트(PreToolUse 등)는 그대로.
        #expect(groups(config, "PreToolUse") == groups(try parse(HooksFixtures.codexHooks), "PreToolUse"))
    }

    @Test func installIsIdempotent() throws {
        var config = try parse(HooksFixtures.claudeSettings)
        try config.install(agent: .claude, jtmPath: jtm)
        let once = config.render()
        let changes = try config.install(agent: .claude, jtmPath: jtm)
        #expect(changes.isEmpty)
        #expect(config.render() == once)
    }

    /// 이전 버전이 설치한 5개 이벤트만 있는 설정에 다시 install하면 새 이벤트(StopFailure, PostToolUse)만 더해지고, 그다음은 변경이 없다.
    @Test func reinstallAddsOnlyTheNewEventsToAnOlderInstall() throws {
        let literal = JSONString(HookCommandFormat.command(agent: .claude, jtmPath: jtm)).literal
        let group = #"{"hooks":[{"type":"command","command":\#(literal),"timeout":5}]}"#
        let oldEvents = ["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "SessionEnd"]
        var config = try parse(#"{"hooks":{"# + oldEvents.map { "\"\($0)\":[\(group)]" }.joined(separator: ",") + "}}")
        #expect(try config.status(agent: .claude, jtmPath: jtm).filter { $0.state == .missing }.map(\.event) == ["StopFailure", "PostToolUse"])

        let changes = try config.install(agent: .claude, jtmPath: jtm)
        #expect(changes.map(\.event) == ["StopFailure", "PostToolUse"] && changes.allSatisfy { $0.kind == .add })
        #expect(try config.status(agent: .claude, jtmPath: jtm).allSatisfy { $0.state == .installed })
        #expect(try config.install(agent: .claude, jtmPath: jtm).isEmpty)
    }

    @Test func installUpdatesOnlyTheCommandWhenThePathChanged() throws {
        var config = try parse(HooksFixtures.claudeSettings)
        try config.install(agent: .claude, jtmPath: "/old/jtm")
        let installed = config

        let changes = try config.install(agent: .claude, jtmPath: "/new/jtm")
        #expect(changes.count == HookAgent.claude.events.count)
        #expect(changes.allSatisfy { $0.kind == .update })
        for event in HookAgent.claude.events {
            #expect(groups(config, event).count == groups(installed, event).count)
            #expect(groups(config, event).last == (try managedGroup(agent: .claude, path: "/new/jtm")))
        }
        // 경로 말고는 아무것도 달라지지 않는다.
        #expect(config.render() == installed.render().replacingOccurrences(of: "'/old/jtm'", with: "'/new/jtm'"))
    }

    @Test func installKeepsAUserEditedTimeout() throws {
        var config = try parse(HooksFixtures.codexHooks)
        try config.install(agent: .codex, jtmPath: "/old/jtm")
        var text = config.render()
        text = text.replacingOccurrences(of: "\"timeout\": 5", with: "\"timeout\": 30")
        config = try parse(text)
        try config.install(agent: .codex, jtmPath: "/new/jtm")
        #expect(config.render().contains("\"timeout\": 30"))
        #expect(config.render().contains("'/new/jtm' ingest codex"))
    }

    @Test func installCreatesHooksObjectInEmptyDocument() throws {
        var config = try HookConfig.parse(Data("{\"theme\": \"dark\"}\n".utf8))
        try config.install(agent: .codex, jtmPath: jtm)
        #expect(config.document.root.objectValue?.map(\.key.value) == ["theme", "hooks"])
        #expect(config.document.root["hooks"]?.objectValue?.map(\.key.value) == HookAgent.codex.events)
        #expect(config.render().hasSuffix("}\n"))
    }

    @Test func uninstallRestoresTheOriginalBytes() throws {
        for (text, agent) in [(HooksFixtures.claudeSettings, HookAgent.claude), (HooksFixtures.codexHooks, .codex)] {
            var config = try parse(text)
            try config.install(agent: agent, jtmPath: jtm)
            #expect(config.render() != text)
            let removed = try config.uninstall(agent: agent)
            #expect(removed.count == agent.events.count)
            #expect(config.render() == text, "\(agent) 설치 후 제거하면 원본과 바이트가 같아야 한다")
        }
    }

    @Test func uninstallLeavesEmptiedByUserArraysAndForeignEntriesAlone() throws {
        var config = try parse(HooksFixtures.claudeSettings)
        // `PreToolUse: []`는 원래 비어 있던 것이라 남고, 표식 없는 jtm ingest 항목과 codex용 항목은 우리 것이 아니다.
        let foreign = try json(#"""
        {"hooks":[{"type":"command","command":"'/x/jtm' ingest claude"},{"type":"command","command":"'/x/jtm' ingest codex # jtm-managed"}]}
        """#)
        var root = config.document.root.objectValue!
        let hooksIndex = root.firstIndex { $0.key.value == "hooks" }!
        var hooks = root[hooksIndex].value.objectValue!
        let stopIndex = hooks.firstIndex { $0.key.value == "Stop" }!
        hooks[stopIndex].value = .array(hooks[stopIndex].value.arrayValue! + [foreign])
        root[hooksIndex].value = .object(hooks)
        config = HookConfig(document: JSONDocument(root: .object(root)))
        let before = config.render()

        try config.install(agent: .claude, jtmPath: jtm)
        try config.uninstall(agent: .claude)
        #expect(config.render() == before)
        #expect(groups(config, "PreToolUse") == [])
        #expect(config.document.root["hooks"]?["PreToolUse"] != nil)
    }

    @Test func uninstallRemovesOnlyOurHookFromAGroupSharedWithOthers() throws {
        let text = """
        {
          "hooks": {
            "Stop": [
              {
                "matcher": "*",
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo mine"
                  },
                  {
                    "type": "command",
                    "command": "'/opt/jtm/bin/jtm' ingest claude # jtm-managed",
                    "timeout": 5
                  }
                ]
              },
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "'/old/jtm' ingest claude # jtm-managed"
                  }
                ]
              }
            ]
          }
        }

        """
        var config = try parse(text)
        let removed = try config.uninstall(agent: .claude)
        #expect(removed == [HookChange(event: "Stop", kind: .remove)])
        #expect(config.render() == """
        {
          "hooks": {
            "Stop": [
              {
                "matcher": "*",
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo mine"
                  }
                ]
              }
            ]
          }
        }

        """)
    }

    @Test func uninstallOnFileWithoutHooksIsANoop() throws {
        let text = "{\n  \"a\": 1\n}\n"
        var config = try parse(text)
        #expect(try config.uninstall(agent: .claude).isEmpty)
        #expect(config.render() == text)
    }

    @Test func statusDistinguishesInstalledMissingAndStale() throws {
        var config = try parse(HooksFixtures.codexHooks)
        #expect(try config.status(agent: .codex, jtmPath: jtm).allSatisfy { $0.state == .missing })

        try config.install(agent: .codex, jtmPath: jtm)
        #expect(try config.status(agent: .codex, jtmPath: jtm).allSatisfy { $0.state == .installed })

        let stale = try config.status(agent: .codex, jtmPath: "/moved/jtm")
        #expect(stale.allSatisfy { $0.state == .stalePath && $0.installedPath == jtm })
        #expect(stale.map(\.event) == HookAgent.codex.events)

        // 한 이벤트만 빠지면 그 이벤트만 missing.
        var partial = config
        var root = partial.document.root.objectValue!
        var hooks = root[0].value.objectValue!
        hooks.removeAll { $0.key.value == "Stop" }
        root[0].value = .object(hooks)
        partial = HookConfig(document: JSONDocument(root: .object(root)))
        let states = Dictionary(uniqueKeysWithValues: try partial.status(agent: .codex, jtmPath: jtm).map { ($0.event, $0.state) })
        #expect(states["Stop"] == .missing)
        #expect(states["SessionStart"] == .installed)
    }

    @Test func statusOfOtherAgentsEntriesIsMissing() throws {
        var config = HookConfig()
        try config.install(agent: .codex, jtmPath: jtm)
        #expect(try config.status(agent: .claude, jtmPath: jtm).allSatisfy { $0.state == .missing })
    }

    @Test func malformedShapesAreReportedNotOverwritten() throws {
        var hooksNotObject = try HookConfig.parse(Data(#"{"hooks": []}"#.utf8))
        #expect(throws: HookConfigError.hooksNotObject) { try hooksNotObject.install(agent: .claude, jtmPath: jtm) }
        var eventNotArray = try HookConfig.parse(Data(#"{"hooks": {"Stop": {}}}"#.utf8))
        #expect(throws: HookConfigError.eventNotArray("Stop")) { try eventNotArray.install(agent: .claude, jtmPath: jtm) }
        #expect(throws: HookConfigError.hooksNotObject) { try hooksNotObject.status(agent: .claude, jtmPath: jtm) }
    }

    @Test func groupsThatAreNotObjectsAreLeftAlone() throws {
        var config = try HookConfig.parse(Data(#"{"hooks": {"Stop": ["weird", 3, {"nohooks": true}]}}"#.utf8))
        try config.install(agent: .claude, jtmPath: jtm)
        #expect(Array(groups(config, "Stop").prefix(3)) == (try json(#"["weird", 3, {"nohooks": true}]"#).arrayValue!))
        try config.uninstall(agent: .claude)
        #expect(groups(config, "Stop").count == 3)
    }
}

// MARK: diff

@Suite struct TextDiffTests {
    @Test func emptyWhenEqual() {
        #expect(TextDiff.unified(old: "a\nb\n", new: "a\nb\n", oldLabel: "x", newLabel: "y").isEmpty)
    }

    @Test func showsAddedLinesWithContext() {
        let old = (1...10).map(String.init).joined(separator: "\n") + "\n"
        var lines = (1...10).map(String.init)
        lines.insert("new", at: 5)
        let diff = TextDiff.unified(old: old, new: lines.joined(separator: "\n") + "\n", oldLabel: "a", newLabel: "b", context: 2)
        #expect(diff == "--- a\n+++ b\n@@ -4,4 +4,5 @@\n 4\n 5\n+new\n 6\n 7\n")
    }

    @Test func separatesDistantChangesAndTruncatesLongLines() {
        let old = (1...30).map(String.init).joined(separator: "\n") + "\n"
        var lines = (1...30).map(String.init)
        lines[1] = "two"
        lines[27] = String(repeating: "x", count: 50)
        let diff = TextDiff.unified(old: old, new: lines.joined(separator: "\n") + "\n", oldLabel: "a", newLabel: "b", maxLineLength: 10)
        #expect(diff.components(separatedBy: "@@ -").count == 3)
        #expect(diff.contains("+xxxxxxxxx…\n"))
        #expect(diff.contains("-2\n+two\n"))
    }

    @Test func handlesCreationFromEmpty() {
        let diff = TextDiff.unified(old: "", new: "{}\n", oldLabel: "(없음)", newLabel: "f")
        #expect(diff == "--- (없음)\n+++ f\n@@ -1,0 +1,1 @@\n+{}\n")
    }
}
