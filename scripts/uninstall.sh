#!/bin/sh
# JTM 제거 스크립트 / JTM uninstaller.
#
#   curl -fsSL https://raw.githubusercontent.com/hiphapis/jtm/main/scripts/uninstall.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/hiphapis/jtm/main/scripts/uninstall.sh | sh -s -- --yes --purge
#
# 하는 일 / What it does:
#   1. 실행 중인 JTM을 종료한다.
#   2. Claude Code/Codex 설정에서 jtm 훅만 뺀다(`jtm hooks uninstall`, 백업을 남긴다).
#   3. ~/.local/bin/jtm 링크(JTM.app 안의 CLI를 가리킬 때만)와 JTM.app 을 지운다.
#   4. 데이터베이스(~/Library/Application Support/jtm)와 로그(~/Library/Logs/jtm)는 --purge 일 때만 지운다.
#
# 옵션 / Options:      --yes, -y   확인하지 않고 진행 (JTM_YES=1)     --purge   데이터와 로그까지 삭제
# 환경 변수 / Environment: JTM_INSTALL_DIR(앱이 있는 폴더. 기본: ~/Applications 와 /Applications 를 찾는다), JTM_YES, JTM_TTY(테스트용)
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
  say "실행 중인 JTM을 종료해요" "Quitting the running JTM ($1)"
  osascript -e "tell application id \"$1\" to quit" >/dev/null 2>&1 &
  quit_pid=$!
  waited=0
  while app_running "$1" && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  kill "$quit_pid" 2>/dev/null || true
  wait "$quit_pid" 2>/dev/null || true
  if app_running "$1"; then
    die "JTM이 5초 안에 종료되지 않았어요. 직접 종료한 뒤 다시 실행해 주세요. (아무것도 지우지 않았어요)" \
        "JTM is still running 5 s after the quit request; quit it and run this again (nothing was removed)."
  fi
}

confirm() {
  if [ "$YES" = 1 ]; then return 0; fi
  tty_device="${JTM_TTY:-/dev/tty}"
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
  if [ "${JTM_YES:-}" = 1 ]; then YES=1; fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes|-y) YES=1 ;;
      --purge) PURGE=1 ;;
      -h|--help)
        printf 'Usage: uninstall.sh [--yes] [--purge]\n  --yes    do not ask for confirmation (same as JTM_YES=1)\n  --purge  also delete the database and logs\n'
        return 0 ;;
      *) die "알 수 없는 옵션: $1 / unknown option: $1" ;;
    esac
    shift
  done

  [ "$(uname -s)" = Darwin ] || die "macOS에서만 쓸 수 있어요." "JTM runs on macOS only."
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME 이 올바르지 않아요." "HOME is not set to a directory."

  # --- 무엇을 지울지 찾는다 ------------------------------------------------------
  app=""
  if [ -n "${JTM_INSTALL_DIR:-}" ]; then
    if [ -d "$JTM_INSTALL_DIR/JTM.app" ]; then app="$JTM_INSTALL_DIR/JTM.app"; fi
  else
    for dir in "$HOME/Applications" /Applications; do
      if [ -d "$dir/JTM.app" ]; then app="$dir/JTM.app"; break; fi
    done
  fi
  link="$HOME/.local/bin/jtm"
  bundle_id="io.github.hiphapis.jtm"
  if [ -n "$app" ]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || echo "$bundle_id")"
  fi
  # 링크는 JTM.app 안의 CLI를 가리킬 때만 우리 것으로 본다(직접 만든 jtm 은 건드리지 않는다).
  own_link=0
  if [ -L "$link" ]; then
    case "$(readlink "$link")" in */JTM.app/Contents/Helpers/jtm) own_link=1 ;; esac
  fi

  say "JTM을 제거해요" "Uninstalling JTM"
  if [ -n "$app" ]; then note "앱: $app" "app: $app"; else note "설치된 JTM.app 을 찾지 못했어요" "JTM.app was not found"; fi
  if [ "$own_link" = 1 ]; then note "CLI 링크: $link" "CLI link: $link"; fi
  note "Claude Code/Codex 설정에서 jtm 훅 제거 (백업을 남겨요)" "jtm hooks are removed from Claude Code/Codex settings (backups are kept)"
  if [ "$PURGE" = 1 ]; then
    note "데이터 삭제(--purge): ~/Library/Application Support/jtm, ~/Library/Logs/jtm — 티켓 기록이 사라져요" \
         "--purge: deletes ~/Library/Application Support/jtm and ~/Library/Logs/jtm (your tickets are lost)"
  else
    note "데이터는 남겨요: ~/Library/Application Support/jtm (지우려면 --purge)" "Your data is kept (use --purge to delete it)"
  fi
  if ! confirm; then note "취소했어요. 아무것도 바꾸지 않았어요." "Cancelled; nothing was changed."; return 0; fi

  # --- 제거 -----------------------------------------------------------------------
  quit_app "$bundle_id"

  # 훅을 먼저 뺀다. 실패하면 CLI를 지우지 않고 멈춘다(없는 jtm 을 부르며 에이전트마다 오류가 나는 일을 막으려고).
  jtm_bin=""
  if [ "$own_link" = 1 ] && [ -x "$link" ]; then jtm_bin="$link"
  elif [ -n "$app" ] && [ -x "$app/Contents/Helpers/jtm" ]; then jtm_bin="$app/Contents/Helpers/jtm"
  fi
  if [ -n "$jtm_bin" ]; then
    say "훅을 제거해요" "Removing the hooks"
    "$jtm_bin" hooks uninstall --claude-settings "$HOME/.claude/settings.json" --codex-hooks "$HOME/.codex/hooks.json" \
      || die "훅을 제거하지 못했어요. 앱과 CLI는 그대로 뒀어요. 설정 파일을 고친 뒤 다시 실행해 주세요." \
             "Removing the hooks failed; the app and CLI were left in place. Fix the settings file and run this again."
  else
    warn "jtm 을 찾지 못해 훅을 제거하지 못했어요. ~/.claude/settings.json 과 ~/.codex/hooks.json 에서 'jtm ingest' 항목을 직접 지워 주세요." \
         "jtm was not found, so hooks could not be removed; delete the 'jtm ingest' entries from ~/.claude/settings.json and ~/.codex/hooks.json."
  fi

  if [ "$own_link" = 1 ]; then
    rm -f "$link"
    say "$link 를 지웠어요" "Removed the CLI link"
  elif [ -e "$link" ] || [ -L "$link" ]; then
    note "$link 는 JTM.app 을 가리키지 않아서 그대로 뒀어요." "Left $link alone (it does not point into JTM.app)."
  fi

  if [ -n "$app" ]; then
    rm -rf "$app"
    say "$app 를 지웠어요" "Removed the app"
  fi

  if [ "$PURGE" = 1 ]; then
    rm -rf "$HOME/Library/Application Support/jtm" "$HOME/Library/Logs/jtm"
    say "데이터와 로그를 지웠어요" "Removed the database and logs"
  fi

  note "로그인 항목에 JTM이 남아 있으면 시스템 설정 > 일반 > 로그인 항목에서 지워 주세요." \
       "If JTM is still listed under System Settings > General > Login Items, remove it there."
  say "제거 완료" "Done."
}

main "$@"
