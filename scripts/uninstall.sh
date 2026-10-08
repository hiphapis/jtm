#!/bin/sh
# Where Was I 제거 스크립트 / Where Was I uninstaller.
#
#   curl -fsSL https://raw.githubusercontent.com/hiphapis/where-was-i/main/scripts/uninstall.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/hiphapis/where-was-i/main/scripts/uninstall.sh | sh -s -- --yes --purge
#
# 하는 일 / What it does (옛 이름 JTM 0.1.x 의 것도 함께 / the legacy JTM names too):
#   1. 실행 중인 앱을 종료한다(번들 ID는 JTM 때와 같다).
#   2. Claude Code/Codex 설정에서 훅만 뺀다(`wwi hooks uninstall`, 옛 `# jtm-managed` 항목도 함께. 백업을 남긴다).
#   3. ~/.local/bin/wwi 링크와 ~/.local/bin/jtm 링크(앱 안의 CLI를 가리킬 때만), Where Was I.app 과 JTM.app 을 지운다.
#   4. 데이터베이스(~/Library/Application Support/jtm)와 로그(~/Library/Logs/jtm)는 --purge 일 때만 지운다.
#
# 옵션 / Options:      --yes, -y   확인하지 않고 진행 (WWI_YES=1)     --purge   데이터와 로그까지 삭제
# 환경 변수 / Environment: WWI_INSTALL_DIR(앱이 있는 폴더. 기본: ~/Applications 와 /Applications 를 찾는다), WWI_YES, WWI_TTY(테스트용)
#
# 모든 코드는 main 함수 안에서 마지막 줄에 호출되므로, 내려받기가 중간에 끊겨도 아무것도 실행되지 않는다.

say() { printf '==> %s\n' "$1"; if [ -n "${2:-}" ]; then printf '    %s\n' "$2"; fi; return 0; }
note() { printf '    %s\n' "$1"; if [ -n "${2:-}" ]; then printf '    %s\n' "$2"; fi; return 0; }
warn() { printf 'warning: %s\n' "$1" >&2; if [ -n "${2:-}" ]; then printf '         %s\n' "$2" >&2; fi; return 0; }
die() { printf 'error: %s\n' "$1" >&2; if [ -n "${2:-}" ]; then printf '       %s\n' "$2" >&2; fi; exit 1; }

app_running() { [ -n "$(lsappinfo find "bundleid=$1" 2>/dev/null)" ]; }

# 떠 있으면 정상 종료를 요청하고 최대 5초 기다린다. 그래도 떠 있으면 아무것도 지우지 않고 실패한다.
quit_app() {
  app_running "$1" || return 0
  say "실행 중인 Where Was I를 종료해요" "Quitting the running Where Was I ($1)"
  osascript -e "tell application id \"$1\" to quit" >/dev/null 2>&1 &
  quit_pid=$!
  waited=0
  while app_running "$1" && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  kill "$quit_pid" 2>/dev/null || true
  wait "$quit_pid" 2>/dev/null || true
  if app_running "$1"; then
    die "Where Was I가 5초 안에 종료되지 않았어요. 직접 종료한 뒤 다시 실행해 주세요. (아무것도 지우지 않았어요)" \
        "Where Was I is still running 5 s after the quit request; quit it and run this again (nothing was removed)."
  fi
}

confirm() {
  if [ "$YES" = 1 ]; then return 0; fi
  tty_device="${WWI_TTY:-/dev/tty}"
  if ! ( : < "$tty_device" ) 2>/dev/null; then
    die "확인할 터미널이 없어요. 그대로 진행하려면 --yes 를 붙여 주세요: curl ... | sh -s -- --yes" \
        "No interactive terminal to confirm on; pass --yes to proceed."
  fi
  printf '계속할까요? [y/N] (Continue?) '
  answer=""
  IFS= read -r answer < "$tty_device" || answer=""
  case "$answer" in y|Y|yes|YES|Yes) return 0 ;; esac
  return 1
}

main() {
  set -eu
  YES=0
  PURGE=0
  if [ "${WWI_YES:-}" = 1 ]; then YES=1; fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes|-y) YES=1 ;;
      --purge) PURGE=1 ;;
      -h|--help)
        printf 'Usage: uninstall.sh [--yes] [--purge]\n  --yes    do not ask for confirmation (same as WWI_YES=1)\n  --purge  also delete the database and logs\n'
        return 0 ;;
      *) die "알 수 없는 옵션: $1 / unknown option: $1" ;;
    esac
    shift
  done

  [ "$(uname -s)" = Darwin ] || die "macOS에서만 쓸 수 있어요." "Where Was I runs on macOS only."
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME 이 올바르지 않아요." "HOME is not set to a directory."

  # --- 무엇을 지울지 찾는다 ------------------------------------------------------
  # 새 이름(Where Was I.app)과 옛 이름(JTM.app)을 모두 찾는다. 둘 다 있을 수도 있다.
  app=""; old_app=""; old_apps=""   # old_app 은 처음 찾은 JTM.app, old_apps 는 찾은 JTM.app 전부(줄바꿈으로 구분)
  if [ -n "${WWI_INSTALL_DIR:-}" ]; then dirs="$WWI_INSTALL_DIR"; else dirs="$HOME/Applications
/Applications"; fi
  old_ifs="$IFS"; IFS='
'
  for dir in $dirs; do
    if [ -z "$app" ] && [ -d "$dir/Where Was I.app" ]; then app="$dir/Where Was I.app"; fi
    if [ -d "$dir/JTM.app" ]; then
      if [ -z "$old_app" ]; then old_app="$dir/JTM.app"; fi
      old_apps="$old_apps$dir/JTM.app
"
    fi
  done
  IFS="$old_ifs"
  link="$HOME/.local/bin/wwi"
  legacy_link="$HOME/.local/bin/jtm"
  bundle_id="io.github.hiphapis.jtm"
  for candidate in "$app" "$old_app"; do
    if [ -n "$candidate" ]; then
      bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist" 2>/dev/null || echo "$bundle_id")"
      break
    fi
  done
  # 링크는 앱 번들 안의 CLI를 가리킬 때만 우리 것으로 본다(직접 만든 wwi/jtm 은 건드리지 않는다).
  own_link=0
  if [ -L "$link" ]; then
    case "$(readlink "$link")" in */Where\ Was\ I.app/Contents/Helpers/wwi) own_link=1 ;; esac
  fi
  own_legacy_link=0
  if [ -L "$legacy_link" ]; then
    # 옛 앱의 CLI를 가리키거나, 설치 스크립트가 훅 이전 실패 때 새 앱의 CLI(Contents/Helpers/wwi)로 돌려 놓은 링크.
    case "$(readlink "$legacy_link")" in */Contents/Helpers/jtm|*/Contents/Helpers/wwi) own_legacy_link=1 ;; esac
  fi

  say "Where Was I를 제거해요" "Uninstalling Where Was I (and the old JTM names, if present)"
  if [ -n "$app" ]; then note "앱: $app" "app: $app"; else note "설치된 Where Was I.app 을 찾지 못했어요" "Where Was I.app was not found"; fi
  old_ifs="$IFS"; IFS='
'
  for found in $old_apps; do note "옛 앱: $found" "old app (JTM): $found"; done
  IFS="$old_ifs"
  if [ "$own_link" = 1 ]; then note "CLI 링크: $link" "CLI link: $link"; fi
  if [ "$own_legacy_link" = 1 ]; then note "옛 CLI 링크: $legacy_link" "old CLI link (jtm): $legacy_link"; fi
  note "Claude Code/Codex 설정에서 wwi 훅(옛 jtm 훅 포함) 제거 (백업을 남겨요)" "wwi hooks (and old jtm hooks) are removed from Claude Code/Codex settings (backups are kept)"
  if [ "$PURGE" = 1 ]; then
    note "데이터 삭제(--purge): ~/Library/Application Support/jtm, ~/Library/Logs/jtm — 티켓 기록이 사라져요" \
         "--purge: deletes ~/Library/Application Support/jtm and ~/Library/Logs/jtm (your tickets are lost)"
  else
    note "데이터는 남겨요: ~/Library/Application Support/jtm (지우려면 --purge)" "Your data is kept (use --purge to delete it)"
  fi
  if ! confirm; then note "취소했어요. 아무것도 바꾸지 않았어요." "Cancelled; nothing was changed."; return 0; fi

  # --- 제거 -----------------------------------------------------------------------
  quit_app "$bundle_id"

  # 훅을 먼저 뺀다. 실패하면 CLI를 지우지 않고 멈춘다(없는 wwi 를 부르며 에이전트마다 오류가 나는 일을 막으려고).
  # 새 wwi 는 옛 `# jtm-managed` 항목도 함께 뺀다. wwi 가 없고 옛 jtm 만 있으면 jtm 으로 뺀다.
  cli_bin=""
  if [ "$own_link" = 1 ] && [ -x "$link" ]; then cli_bin="$link"
  elif [ -n "$app" ] && [ -x "$app/Contents/Helpers/wwi" ]; then cli_bin="$app/Contents/Helpers/wwi"
  elif [ "$own_legacy_link" = 1 ] && [ -x "$legacy_link" ]; then cli_bin="$legacy_link"
  elif [ -n "$old_app" ] && [ -x "$old_app/Contents/Helpers/jtm" ]; then cli_bin="$old_app/Contents/Helpers/jtm"
  fi
  if [ -n "$cli_bin" ]; then
    say "훅을 제거해요" "Removing the hooks"
    "$cli_bin" hooks uninstall --claude-settings "$HOME/.claude/settings.json" --codex-hooks "$HOME/.codex/hooks.json" \
      || die "훅을 제거하지 못했어요. 앱과 CLI는 그대로 뒀어요. 설정 파일을 고친 뒤 다시 실행해 주세요." \
             "Removing the hooks failed; the app and CLI were left in place. Fix the settings file and run this again."
  else
    warn "wwi 를 찾지 못해 훅을 제거하지 못했어요. ~/.claude/settings.json 과 ~/.codex/hooks.json 에서 'wwi ingest'(옛 'jtm ingest') 항목을 직접 지워 주세요." \
         "wwi was not found, so hooks could not be removed; delete the 'wwi ingest' (old 'jtm ingest') entries from ~/.claude/settings.json and ~/.codex/hooks.json."
  fi

  if [ "$own_link" = 1 ]; then
    rm -f "$link"
    say "$link 를 지웠어요" "Removed the CLI link"
  elif [ -e "$link" ] || [ -L "$link" ]; then
    note "$link 는 Where Was I.app 을 가리키지 않아서 그대로 뒀어요." "Left $link alone (it does not point into Where Was I.app)."
  fi
  if [ "$own_legacy_link" = 1 ]; then
    rm -f "$legacy_link"
    say "옛 $legacy_link 를 지웠어요" "Removed the old jtm link"
  elif [ -e "$legacy_link" ] || [ -L "$legacy_link" ]; then
    note "$legacy_link 는 앱을 가리키지 않아서 그대로 뒀어요." "Left $legacy_link alone (it does not point into an app bundle)."
  fi

  if [ -n "$app" ]; then
    rm -rf "$app"
    say "$app 를 지웠어요" "Removed the app"
  fi
  old_ifs="$IFS"; IFS='
'
  for found in $old_apps; do
    rm -rf "$found"
    say "$found 를 지웠어요" "Removed the old app (JTM)"
  done
  IFS="$old_ifs"

  if [ "$PURGE" = 1 ]; then
    rm -rf "$HOME/Library/Application Support/jtm" "$HOME/Library/Logs/jtm"
    say "데이터와 로그를 지웠어요" "Removed the database and logs"
  fi

  note "로그인 항목에 Where Was I(또는 JTM)가 남아 있으면 시스템 설정 > 일반 > 로그인 항목에서 지워 주세요." \
       "If Where Was I (or JTM) is still listed under System Settings > General > Login Items, remove it there."
  say "제거 완료" "Done."
}

main "$@"
