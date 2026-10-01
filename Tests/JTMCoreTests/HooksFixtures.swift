import Foundation

// 실제 `~/.claude/settings.json`, `~/.codex/hooks.json`의 모양을 본떠 만든 테스트 픽스처.
// Orca가 넣은 긴 훅 명령은 실제 파일에서 그대로 옮긴 것이고, 나머지는 손으로 다듬었다(개인 설정은 뺐다).
// 원문 바이트가 중요해서 전부 raw 문자열 리터럴(`#"""`)이다.
enum HooksFixtures {
    /// Orca가 Claude 설정에 넣는 훅 명령의 JSON 리터럴(따옴표 포함, 이스케이프 원문 그대로).
    static let orcaClaudeCommandLiteral = #"""
"if [ -z \"${HOME-}\" ]; then case \"${OSTYPE-}\" in msys*|cygwin*|win32*) printf '{}\\n'; if [ -z \"${ORCA_AGENT_HOOK_PORT-}\" ] || [ -z \"${ORCA_AGENT_HOOK_TOKEN-}\" ] || [ -z \"${ORCA_PANE_KEY-}\" ]; then exit 0; fi; { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || : ;; *) { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; printf '{}\\n' ;; esac; else case \"${OSTYPE-}\" in msys*|cygwin*|win32*) if [ -f \"${HOME-}/.orca/agent-hooks/claude-hook.cmd\" ]; then case \"${HOME-}\" in *\\&*|*\\^*|*\\(*|*\\)*|*\\;*|*,*|*=*|*%*|*\\!*) if [ -f \"${SYSTEMROOT-}/System32/WindowsPowerShell/v1.0/powershell.exe\" ]; then \"${SYSTEMROOT-}/System32/WindowsPowerShell/v1.0/powershell.exe\" -NoProfile -EncodedCommand JABQAHIAbwBnAHIAZQBzAHMAUAByAGUAZgBlAHIAZQBuAGMAZQA9ACcAUwBpAGwAZQBuAHQAbAB5AEMAbwBuAHQAaQBuAHUAZQAnADsAIAB0AHIAeQAgAHsAIABTAGUAdAAtAEUAeABlAGMAdQB0AGkAbwBuAFAAbwBsAGkAYwB5ACAALQBTAGMAbwBwAGUAIABQAHIAbwBjAGUAcwBzACAALQBFAHgAZQBjAHUAdABpAG8AbgBQAG8AbABpAGMAeQAgAEIAeQBwAGEAcwBzACAALQBGAG8AcgBjAGUAIAAtAEUAcgByAG8AcgBBAGMAdABpAG8AbgAgAFMAaQBsAGUAbgB0AGwAeQBDAG8AbgB0AGkAbgB1AGUAIAB9ACAAYwBhAHQAYwBoACAAewB9ADsAIAAkAGgAbwBtAGUAUABhAHQAaAAgAD0AIAAkAGUAbgB2ADoASABPAE0ARQAgAC0AcgBlAHAAbABhAGMAZQAgACcAXgAvACgAWwBBAC0AWgBhAC0AegBdACkALwAnACwAIAAnACQAMQA6AC8AJwA7ACAAJABzAGMAcgBpAHAAdABQAGEAdABoACAAPQAgAEoAbwBpAG4ALQBQAGEAdABoACAAJABoAG8AbQBlAFAAYQB0AGgAIAAnAC4AbwByAGMAYQBcAGEAZwBlAG4AdAAtAGgAbwBvAGsAcwBcAGMAbABhAHUAZABlAC0AaABvAG8AawAuAGMAbQBkACcAOwAgAGkAZgAgACgAVABlAHMAdAAtAFAAYQB0AGgAIAAtAEwAaQB0AGUAcgBhAGwAUABhAHQAaAAgACQAcwBjAHIAaQBwAHQAUABhAHQAaAAgAC0AUABhAHQAaABUAHkAcABlACAATABlAGEAZgApACAAewAgACYAIAAkAHMAYwByAGkAcAB0AFAAYQB0AGgAOwAgAGUAeABpAHQAIAAkAEwAQQBTAFQARQBYAEkAVABDAE8ARABFACAAfQA7ACAAVwByAGkAdABlAC0ATwB1AHQAcAB1AHQAIAAnAHsAfQAnADsAIABpAGYAIAAoAC0AbgBvAHQAIAAkAGUAbgB2ADoATwBSAEMAQQBfAEEARwBFAE4AVABfAEgATwBPAEsAXwBQAE8AUgBUACAALQBvAHIAIAAtAG4AbwB0ACAAJABlAG4AdgA6AE8AUgBDAEEAXwBBAEcARQBOAFQAXwBIAE8ATwBLAF8AVABPAEsARQBOACAALQBvAHIAIAAtAG4AbwB0ACAAJABlAG4AdgA6AE8AUgBDAEEAXwBQAEEATgBFAF8ASwBFAFkAKQAgAHsAIABlAHgAaQB0ACAAMAAgAH0AOwAgAFsAQwBvAG4AcwBvAGwAZQBdADoAOgBJAG4ALgBSAGUAYQBkAFQAbwBFAG4AZAAoACkAIAB8ACAATwB1AHQALQBOAHUAbABsADsAIABlAHgAaQB0ACAAMAA=; else printf '{}\\n'; if [ -z \"${ORCA_AGENT_HOOK_PORT-}\" ] || [ -z \"${ORCA_AGENT_HOOK_TOKEN-}\" ] || [ -z \"${ORCA_PANE_KEY-}\" ]; then exit 0; fi; { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi ;; *) \"${HOME-}/.orca/agent-hooks/claude-hook.cmd\" ;; esac; else printf '{}\\n'; if [ -z \"${ORCA_AGENT_HOOK_PORT-}\" ] || [ -z \"${ORCA_AGENT_HOOK_TOKEN-}\" ] || [ -z \"${ORCA_PANE_KEY-}\" ]; then exit 0; fi; { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi ;; *) if [ -f \"${HOME-}/.orca/agent-hooks/claude-hook.sh\" ] && [ -r \"${HOME-}/.orca/agent-hooks/claude-hook.sh\" ] && [ -x \"${HOME-}/.orca/agent-hooks/claude-hook.sh\" ]; then /bin/sh \"${HOME-}/.orca/agent-hooks/claude-hook.sh\"; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; printf '{}\\n'; fi ;; esac; fi"
"""#

    /// 원본 파일과 같은 서식(2칸 들여쓰기, 끝 개행)이지만 일부러 이스케이프·숫자 표기·빈 컨테이너를 섞었다.
    static let claudeSettings = #"""
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "hooks": {
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "afplay /System/Library/Sounds/Glass.aiff"
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": \#(orcaClaudeCommandLiteral),
            "timeout": 10
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "afplay /System/Library/Sounds/Ping.aiff"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "echo '세션 시작 \u2728'"
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": \#(orcaClaudeCommandLiteral),
            "timeout": 10
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": \#(orcaClaudeCommandLiteral),
            "timeout": 10
          }
        ]
      }
    ],
    "PreToolUse": []
  },
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  },
  "enabledPlugins": {
    "example@marketplace": true
  },
  "language": "korean",
  "ratio": 1.50,
  "big": 12345678901234567890,
  "escaped": "a\/b \u00e9 \ud83d\ude00 \"q\" tab\t",
  "emptyObject": {},
  "emptyArray": [],
  "nested": {
    "list": [
      1,
      null,
      true
    ]
  },
  "model": "sonnet"
}
"""# + "\n"

    /// 실제 `~/.codex/hooks.json` 전체(Orca가 관리하는 항목).
    static let codexHooks = #"""
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "if [ -f '/Users/me/.orca/agent-hooks/codex-hook.sh' ] && [ -r '/Users/me/.orca/agent-hooks/codex-hook.sh' ] && [ -x '/Users/me/.orca/agent-hooks/codex-hook.sh' ]; then /bin/sh '/Users/me/.orca/agent-hooks/codex-hook.sh'; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi",
            "timeout": 10
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "if [ -f '/Users/me/.orca/agent-hooks/codex-hook.sh' ] && [ -r '/Users/me/.orca/agent-hooks/codex-hook.sh' ] && [ -x '/Users/me/.orca/agent-hooks/codex-hook.sh' ]; then /bin/sh '/Users/me/.orca/agent-hooks/codex-hook.sh'; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi",
            "timeout": 10
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "if [ -f '/Users/me/.orca/agent-hooks/codex-hook.sh' ] && [ -r '/Users/me/.orca/agent-hooks/codex-hook.sh' ] && [ -x '/Users/me/.orca/agent-hooks/codex-hook.sh' ]; then /bin/sh '/Users/me/.orca/agent-hooks/codex-hook.sh'; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi",
            "timeout": 10
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "if [ -f '/Users/me/.orca/agent-hooks/codex-hook.sh' ] && [ -r '/Users/me/.orca/agent-hooks/codex-hook.sh' ] && [ -x '/Users/me/.orca/agent-hooks/codex-hook.sh' ]; then /bin/sh '/Users/me/.orca/agent-hooks/codex-hook.sh'; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi",
            "timeout": 10
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "if [ -f '/Users/me/.orca/agent-hooks/codex-hook.sh' ] && [ -r '/Users/me/.orca/agent-hooks/codex-hook.sh' ] && [ -x '/Users/me/.orca/agent-hooks/codex-hook.sh' ]; then /bin/sh '/Users/me/.orca/agent-hooks/codex-hook.sh'; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi",
            "timeout": 10
          }
        ]
      }
    ],
    "SubagentStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "if [ -f '/Users/me/.orca/agent-hooks/codex-hook.sh' ] && [ -r '/Users/me/.orca/agent-hooks/codex-hook.sh' ] && [ -x '/Users/me/.orca/agent-hooks/codex-hook.sh' ]; then /bin/sh '/Users/me/.orca/agent-hooks/codex-hook.sh'; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi",
            "timeout": 10
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "if [ -f '/Users/me/.orca/agent-hooks/codex-hook.sh' ] && [ -r '/Users/me/.orca/agent-hooks/codex-hook.sh' ] && [ -x '/Users/me/.orca/agent-hooks/codex-hook.sh' ]; then /bin/sh '/Users/me/.orca/agent-hooks/codex-hook.sh'; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "if [ -f '/Users/me/.orca/agent-hooks/codex-hook.sh' ] && [ -r '/Users/me/.orca/agent-hooks/codex-hook.sh' ] && [ -x '/Users/me/.orca/agent-hooks/codex-hook.sh' ]; then /bin/sh '/Users/me/.orca/agent-hooks/codex-hook.sh'; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
"""# + "\n"
}
