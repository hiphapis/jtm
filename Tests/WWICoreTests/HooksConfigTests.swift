import Foundation
import Testing
@testable import WWICore

private let wwi = "/opt/wwi/bin/wwi"

private func parse(_ text: String) throws -> HookConfig {
    try HookConfig.parse(Data(text.utf8))
}

private func groups(_ config: HookConfig, _ event: String) -> [JSONValue] {
    config.document.root["hooks"]?[event]?.arrayValue ?? []
}

private func json(_ text: String) throws -> JSONValue {
    try JSONDocument.parse(Data(text.utf8)).root
}

private func managedGroup(agent: HookAgent, path: String = wwi) throws -> JSONValue {
    try json("""
    {"hooks":[{"type":"command","command":\(JSONString(HookCommandFormat.command(agent: agent, wwiPath: path)).literal),"timeout":5}]}
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
        #expect(HookCommandFormat.command(agent: .claude, wwiPath: "/a/wwi") == "'/a/wwi' ingest claude # wwi-managed")
        #expect(HookCommandFormat.command(agent: .codex, wwiPath: "/my dir/it's/wwi")
            == #"'/my dir/it'\''s/wwi' ingest codex # wwi-managed"#)
    }

    @Test func extractsPathFromQuotedCommand() {
        for path in ["/a/wwi", "/my dir/it's/wwi", "/opt/wwi/bin/wwi"] {
            let command = HookCommandFormat.command(agent: .claude, wwiPath: path)
            #expect(HookCommandFormat.wwiPath(in: command) == path)
        }
    }

    @Test func recognizesOnlyOurOwnEntries() {
        let ours = HookCommandFormat.command(agent: .claude, wwiPath: "/x/wwi")
        #expect(HookCommandFormat.isManaged(ours, agent: .claude))
        #expect(!HookCommandFormat.isManaged(ours, agent: .codex))
        // 표식이 없으면 남의 항목이다(사용자가 직접 wwi ingest를 걸어 둔 경우).
        #expect(!HookCommandFormat.isManaged("'/x/wwi' ingest claude", agent: .claude))
        #expect(!HookCommandFormat.isManaged("echo hi # wwi-managed", agent: .claude))
        // 상대 경로는 우리가 만든 형식이 아니다.
        #expect(!HookCommandFormat.isManaged("wwi ingest claude # wwi-managed", agent: .claude))
    }

    @Test func rejectsRelativeOrControlCharacterPaths() throws {
        var config = HookConfig()
        #expect(throws: HookConfigError.invalidWWIPath("wwi")) { try config.install(agent: .claude, wwiPath: "wwi") }
        #expect(throws: HookConfigError.self) { try config.install(agent: .claude, wwiPath: "/a\n/wwi") }
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
        let changes = try config.install(agent: .claude, wwiPath: wwi)

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
        let changes = try config.install(agent: .codex, wwiPath: wwi)
        #expect(changes.map(\.event) == HookAgent.codex.events)
        for event in HookAgent.codex.events {
            #expect(groups(config, event).last == (try managedGroup(agent: .codex)))
        }
        // Orca가 관리하는 다른 이벤트(PreToolUse 등)는 그대로.
        #expect(groups(config, "PreToolUse") == groups(try parse(HooksFixtures.codexHooks), "PreToolUse"))
    }

    @Test func installIsIdempotent() throws {
        var config = try parse(HooksFixtures.claudeSettings)
        try config.install(agent: .claude, wwiPath: wwi)
        let once = config.render()
        let changes = try config.install(agent: .claude, wwiPath: wwi)
        #expect(changes.isEmpty)
        #expect(config.render() == once)
    }

    /// 이전 버전이 설치한 5개 이벤트만 있는 설정에 다시 install하면 새 이벤트(StopFailure, PostToolUse)만 더해지고, 그다음은 변경이 없다.
    @Test func reinstallAddsOnlyTheNewEventsToAnOlderInstall() throws {
        let literal = JSONString(HookCommandFormat.command(agent: .claude, wwiPath: wwi)).literal
        let group = #"{"hooks":[{"type":"command","command":\#(literal),"timeout":5}]}"#
        let oldEvents = ["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "SessionEnd"]
        var config = try parse(#"{"hooks":{"# + oldEvents.map { "\"\($0)\":[\(group)]" }.joined(separator: ",") + "}}")
        #expect(try config.status(agent: .claude, wwiPath: wwi).filter { $0.state == .missing }.map(\.event) == ["StopFailure", "PostToolUse"])

        let changes = try config.install(agent: .claude, wwiPath: wwi)
        #expect(changes.map(\.event) == ["StopFailure", "PostToolUse"] && changes.allSatisfy { $0.kind == .add })
        #expect(try config.status(agent: .claude, wwiPath: wwi).allSatisfy { $0.state == .installed })
        #expect(try config.install(agent: .claude, wwiPath: wwi).isEmpty)
    }

    @Test func installUpdatesOnlyTheCommandWhenThePathChanged() throws {
        var config = try parse(HooksFixtures.claudeSettings)
        try config.install(agent: .claude, wwiPath: "/old/wwi")
        let installed = config

        let changes = try config.install(agent: .claude, wwiPath: "/new/wwi")
        #expect(changes.count == HookAgent.claude.events.count)
        #expect(changes.allSatisfy { $0.kind == .update })
        for event in HookAgent.claude.events {
            #expect(groups(config, event).count == groups(installed, event).count)
            #expect(groups(config, event).last == (try managedGroup(agent: .claude, path: "/new/wwi")))
        }
        // 경로 말고는 아무것도 달라지지 않는다.
        #expect(config.render() == installed.render().replacingOccurrences(of: "'/old/wwi'", with: "'/new/wwi'"))
    }

    @Test func installKeepsAUserEditedTimeout() throws {
        var config = try parse(HooksFixtures.codexHooks)
        try config.install(agent: .codex, wwiPath: "/old/wwi")
        var text = config.render()
        text = text.replacingOccurrences(of: "\"timeout\": 5", with: "\"timeout\": 30")
        config = try parse(text)
        try config.install(agent: .codex, wwiPath: "/new/wwi")
        #expect(config.render().contains("\"timeout\": 30"))
        #expect(config.render().contains("'/new/wwi' ingest codex"))
    }

    @Test func installCreatesHooksObjectInEmptyDocument() throws {
        var config = try HookConfig.parse(Data("{\"theme\": \"dark\"}\n".utf8))
        try config.install(agent: .codex, wwiPath: wwi)
        #expect(config.document.root.objectValue?.map(\.key.value) == ["theme", "hooks"])
        #expect(config.document.root["hooks"]?.objectValue?.map(\.key.value) == HookAgent.codex.events)
        #expect(config.render().hasSuffix("}\n"))
    }

    @Test func uninstallRestoresTheOriginalBytes() throws {
        for (text, agent) in [(HooksFixtures.claudeSettings, HookAgent.claude), (HooksFixtures.codexHooks, .codex)] {
            var config = try parse(text)
            try config.install(agent: agent, wwiPath: wwi)
            #expect(config.render() != text)
            let removed = try config.uninstall(agent: agent)
            #expect(removed.count == agent.events.count)
            #expect(config.render() == text, "\(agent) 설치 후 제거하면 원본과 바이트가 같아야 한다")
        }
    }

    @Test func uninstallLeavesEmptiedByUserArraysAndForeignEntriesAlone() throws {
        var config = try parse(HooksFixtures.claudeSettings)
        // `PreToolUse: []`는 원래 비어 있던 것이라 남고, 표식 없는 wwi ingest 항목과 codex용 항목은 우리 것이 아니다.
        let foreign = try json(#"""
        {"hooks":[{"type":"command","command":"'/x/wwi' ingest claude"},{"type":"command","command":"'/x/wwi' ingest codex # wwi-managed"}]}
        """#)
        var root = config.document.root.objectValue!
        let hooksIndex = root.firstIndex { $0.key.value == "hooks" }!
        var hooks = root[hooksIndex].value.objectValue!
        let stopIndex = hooks.firstIndex { $0.key.value == "Stop" }!
        hooks[stopIndex].value = .array(hooks[stopIndex].value.arrayValue! + [foreign])
        root[hooksIndex].value = .object(hooks)
        config = HookConfig(document: JSONDocument(root: .object(root)))
        let before = config.render()

        try config.install(agent: .claude, wwiPath: wwi)
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
                    "command": "'/opt/wwi/bin/wwi' ingest claude # wwi-managed",
                    "timeout": 5
                  }
                ]
              },
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "'/old/wwi' ingest claude # wwi-managed"
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
        #expect(try config.status(agent: .codex, wwiPath: wwi).allSatisfy { $0.state == .missing })

        try config.install(agent: .codex, wwiPath: wwi)
        #expect(try config.status(agent: .codex, wwiPath: wwi).allSatisfy { $0.state == .installed })

        let stale = try config.status(agent: .codex, wwiPath: "/moved/wwi")
        #expect(stale.allSatisfy { $0.state == .stalePath && $0.installedPath == wwi })
        #expect(stale.map(\.event) == HookAgent.codex.events)

        // 한 이벤트만 빠지면 그 이벤트만 missing.
        var partial = config
        var root = partial.document.root.objectValue!
        var hooks = root[0].value.objectValue!
        hooks.removeAll { $0.key.value == "Stop" }
        root[0].value = .object(hooks)
        partial = HookConfig(document: JSONDocument(root: .object(root)))
        let states = Dictionary(uniqueKeysWithValues: try partial.status(agent: .codex, wwiPath: wwi).map { ($0.event, $0.state) })
        #expect(states["Stop"] == .missing)
        #expect(states["SessionStart"] == .installed)
    }

    @Test func statusOfOtherAgentsEntriesIsMissing() throws {
        var config = HookConfig()
        try config.install(agent: .codex, wwiPath: wwi)
        #expect(try config.status(agent: .claude, wwiPath: wwi).allSatisfy { $0.state == .missing })
    }

    @Test func malformedShapesAreReportedNotOverwritten() throws {
        var hooksNotObject = try HookConfig.parse(Data(#"{"hooks": []}"#.utf8))
        #expect(throws: HookConfigError.hooksNotObject) { try hooksNotObject.install(agent: .claude, wwiPath: wwi) }
        var eventNotArray = try HookConfig.parse(Data(#"{"hooks": {"Stop": {}}}"#.utf8))
        #expect(throws: HookConfigError.eventNotArray("Stop")) { try eventNotArray.install(agent: .claude, wwiPath: wwi) }
        #expect(throws: HookConfigError.hooksNotObject) { try hooksNotObject.status(agent: .claude, wwiPath: wwi) }
    }

    @Test func groupsThatAreNotObjectsAreLeftAlone() throws {
        var config = try HookConfig.parse(Data(#"{"hooks": {"Stop": ["weird", 3, {"nohooks": true}]}}"#.utf8))
        try config.install(agent: .claude, wwiPath: wwi)
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

// MARK: 옛 이름(JTM 0.1.x)의 `# jtm-managed` 항목

private let legacyPath = "/Users/me/.local/bin/jtm"

/// 0.1.x가 쓰던 모양 그대로: `'<abs>/jtm' ingest <agent> # jtm-managed`.
private func legacyConfig(_ base: String, agent: HookAgent) throws -> HookConfig {
    var config = try parse(base)
    try config.install(agent: agent, wwiPath: legacyPath)
    let text = config.render().replacingOccurrences(of: "# wwi-managed", with: "# jtm-managed")
    return try parse(text)
}

private func managedCommands(_ config: HookConfig, agent: HookAgent, event: String) -> [String] {
    groups(config, event).flatMap { $0["hooks"]?.arrayValue ?? [] }.compactMap { $0["command"]?.stringValue }
        .filter { HookCommandFormat.isManaged($0, agent: agent) }
}

@Suite struct HookLegacyMarkerTests {
    @Test func theNewMarkerAndCommandShape() {
        #expect(HookCommandFormat.marker == "# wwi-managed")
        #expect(HookCommandFormat.command(agent: .claude, wwiPath: "/a b/wwi") == "'/a b/wwi' ingest claude # wwi-managed")
    }

    @Test func legacyEntriesAreRecognisedAsOurs() throws {
        let legacy = "'\(legacyPath)' ingest claude # jtm-managed"
        #expect(HookCommandFormat.isManaged(legacy, agent: .claude))
        #expect(HookCommandFormat.isLegacy(legacy, agent: .claude))
        #expect(!HookCommandFormat.isManaged(legacy, agent: .codex))  // 에이전트가 다르면 우리 항목이 아니다
        let current = HookCommandFormat.command(agent: .claude, wwiPath: wwi)
        #expect(HookCommandFormat.isManaged(current, agent: .claude) && !HookCommandFormat.isLegacy(current, agent: .claude))
        // 옛 표식과 절대 경로면 경로 이름이 무엇이든 우리 항목이다(`--jtm-path`로 직접 지정한 경로도 이전한다).
        for custom in ["/opt/x/jtm-dev", "/usr/bin/other"] {
            let command = "'\(custom)' ingest claude # jtm-managed"
            #expect(HookCommandFormat.isManaged(command, agent: .claude) && HookCommandFormat.isLegacy(command, agent: .claude))
        }
        // 절대 경로가 아니면 우리 것이 아니다(사용자가 직접 쓴 명령을 건드리지 않는다).
        #expect(!HookCommandFormat.isManaged("jtm ingest claude # jtm-managed", agent: .claude))
        #expect(!HookCommandFormat.isManaged("'jtm' ingest claude # jtm-managed", agent: .claude))
    }

    @Test func statusReportsLegacyEntriesAsNeedingAnUpdate() throws {
        let config = try legacyConfig(HooksFixtures.claudeSettings, agent: .claude)
        let events = try config.status(agent: .claude, wwiPath: wwi)
        #expect(events.map(\.event) == HookAgent.claude.events)
        #expect(events.allSatisfy { $0.state == .legacy && $0.installedPath == legacyPath })
        #expect(try config.status(agent: .claude, wwiPath: legacyPath).allSatisfy { $0.state == .legacy })  // 경로가 같아도 옛 표식이면 갱신 대상
    }

    @Test func installReplacesLegacyEntriesInPlaceWithExactlyOnePerEvent() throws {
        var config = try legacyConfig(HooksFixtures.claudeSettings, agent: .claude)
        let before = config.render()
        let changes = try config.install(agent: .claude, wwiPath: wwi)

        #expect(changes.count == HookAgent.claude.events.count && changes.allSatisfy { $0.kind == .update })
        let after = config.render()
        #expect(!after.contains("jtm-managed") && !after.contains(legacyPath))
        for event in HookAgent.claude.events {
            #expect(managedCommands(config, agent: .claude, event: event) == [HookCommandFormat.command(agent: .claude, wwiPath: wwi)], "\(event)")
            #expect(groups(config, event).count == groups(try parse(before), event).count, "제자리 교체: 그룹 수가 그대로여야 한다 \(event)")
        }
        #expect(try config.status(agent: .claude, wwiPath: wwi).allSatisfy { $0.state == .installed })
        // 한 번 더 실행해도 변화 없음.
        #expect(try config.install(agent: .claude, wwiPath: wwi).isEmpty)
        #expect(config.render() == after)
    }

    @Test func installCollapsesALegacyAndANewEntryOfTheSameEventIntoOne() throws {
        var config = try legacyConfig(HooksFixtures.claudeSettings, agent: .claude)
        // 같은 이벤트에 새 항목을 별도 그룹으로 덧붙여 둔 상태(옛 훅 + 새 훅이 함께 있는 경우)를 만든다.
        var root = config.document.root.objectValue!
        var hooks = root[root.firstIndex { $0.key.value == "hooks" }!].value.objectValue!
        let stopIndex = hooks.firstIndex { $0.key.value == "Stop" }!
        var stop = hooks[stopIndex].value.arrayValue!
        stop.append(try managedGroup(agent: .claude))
        hooks[stopIndex].value = .array(stop)
        root[root.firstIndex { $0.key.value == "hooks" }!].value = .object(hooks)
        config = HookConfig(document: JSONDocument(root: .object(root)))
        #expect(managedCommands(config, agent: .claude, event: "Stop").count == 2)

        try config.install(agent: .claude, wwiPath: wwi)

        for event in HookAgent.claude.events {
            #expect(managedCommands(config, agent: .claude, event: event).count == 1, "\(event)")
        }
        #expect(!config.render().contains("jtm-managed"))
    }

    @Test func uninstallRemovesLegacyEntriesAndKeepsTheRest() throws {
        var config = try legacyConfig(HooksFixtures.claudeSettings, agent: .claude)
        let changes = try config.uninstall(agent: .claude)
        #expect(changes.count == HookAgent.claude.events.count && changes.allSatisfy { $0.kind == .remove })
        #expect(!config.render().contains("jtm-managed"))
        // 사용자가 원래 갖고 있던 훅은 그대로다: 처음 상태(관리 항목 없음)와 같다.
        #expect(config.render() == (try parse(HooksFixtures.claudeSettings)).render())
    }

    @Test func aCustomJtmPathIsMigratedToo() throws {
        // `--jtm-path /opt/x/jtm-dev`처럼 이름이 `jtm`으로 끝나지 않는 경로로 설치한 옛 훅도 알아보고 바꾼다.
        var config = try parse(HooksFixtures.claudeSettings)
        try config.install(agent: .claude, wwiPath: "/opt/x/jtm-dev")
        config = try parse(config.render().replacingOccurrences(of: "# wwi-managed", with: "# jtm-managed"))
        #expect(try config.status(agent: .claude, wwiPath: wwi).allSatisfy { $0.state == .legacy && $0.installedPath == "/opt/x/jtm-dev" })
        try config.install(agent: .claude, wwiPath: wwi)
        #expect(!config.render().contains("jtm-managed") && !config.render().contains("jtm-dev"))
        for event in HookAgent.claude.events {
            #expect(managedCommands(config, agent: .claude, event: event) == [HookCommandFormat.command(agent: .claude, wwiPath: wwi)], "\(event)")
        }
    }

    @Test func codexLegacyEntriesAreMigratedToo() throws {
        var config = try legacyConfig(HooksFixtures.codexHooks, agent: .codex)
        #expect(try config.status(agent: .codex, wwiPath: wwi).allSatisfy { $0.state == .legacy })
        try config.install(agent: .codex, wwiPath: wwi)
        #expect(try config.status(agent: .codex, wwiPath: wwi).allSatisfy { $0.state == .installed })
        #expect(!config.render().contains("jtm-managed"))
    }
}
