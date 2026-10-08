#!/bin/sh
# Where Was I 설치 스크립트 / Where Was I installer (macOS 14+, Apple Silicon and Intel).
#
#   curl -fsSL https://raw.githubusercontent.com/hiphapis/where-was-i/main/scripts/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/hiphapis/where-was-i/main/scripts/install.sh | sh -s -- --yes
#
# 하는 일 / What it does:
#   1. GitHub Releases에서 WhereWasI-<version>.zip 과 .sha256 을 받아 체크섬을 확인한다.
#   2. 실행 중인 앱을 종료하고 ~/Applications/Where Was I.app 을 교체한다.
#   3. ~/.local/bin/wwi 를 앱 안의 CLI(Where Was I.app/Contents/Helpers/wwi)로 연결한다.
#   4. 물어본 뒤(또는 --yes) Claude Code / Codex 훅을 설치한다(`wwi hooks install`, 백업을 남긴다).
#   5. 앱을 `open`으로 연다. 앱 안의 실행 파일을 직접 실행하지 않는다.
#
# JTM(0.1.x)에서 올리는 경우: 번들 ID가 같아서 실행 중인 JTM도 종료한다. 순서는 새 앱 설치 → wwi 링크 → 훅 이전이고,
# 그 뒤에야 옛 JTM.app(~/Applications 와 /Applications 둘 다)과 옛 ~/.local/bin/jtm 링크를 지운다(옛 훅이 없는 파일을 부르는 순간이 없게).
# 옛 `# jtm-managed` 훅이 있으면 묻지 않고 `wwi hooks install` 로 새 항목으로 바꾼다(이미 쓰고 있던 훅이라서).
# 이전이 실패하면 옛 jtm 링크를 새 앱의 wwi 로 돌려 놓아 옛 훅이 계속 동작하게 한 뒤 옛 앱을 지운다.
#
# 옵션 / Options:        --yes, -y        훅 설치를 묻지 않고 진행 (WWI_YES=1 과 같다)
#                        --version X.Y.Z  특정 버전 (WWI_VERSION 과 같다)
# 환경 변수 / Environment:
#   WWI_VERSION       설치할 버전(기본: 최신 릴리스)
#   WWI_INSTALL_DIR   앱을 둘 폴더(기본: ~/Applications)
#   WWI_YES=1         훅 설치 질문을 건너뛰고 설치
#   WWI_REPO          GitHub 저장소(기본: hiphapis/where-was-i)
#   WWI_RELEASE_URL   테스트용: WhereWasI-<version>.zip 과 .sha256 이 있는 폴더 주소(file:// 포함). 설정하면 GitHub API를 부르지 않는다.
#   WWI_TTY           테스트용: 질문에 답을 읽을 장치(기본: /dev/tty)
#
# 모든 코드는 main 함수 안에서 마지막 줄에 호출되므로, 내려받기가 중간에 끊겨도 아무것도 실행되지 않는다.

say() { printf '==> %s\n' "$1"; if [ -n "${2:-}" ]; then printf '    %s\n' "$2"; fi; return 0; }
note() { printf '    %s\n' "$1"; if [ -n "${2:-}" ]; then printf '    %s\n' "$2"; fi; return 0; }
warn() { printf 'warning: %s\n' "$1" >&2; if [ -n "${2:-}" ]; then printf '         %s\n' "$2" >&2; fi; return 0; }
die() { printf 'error: %s\n' "$1" >&2; if [ -n "${2:-}" ]; then printf '       %s\n' "$2" >&2; fi; exit 1; }

app_running() { [ -n "$(lsappinfo find "bundleid=$1" 2>/dev/null)" ]; }

# 떠 있으면 정상 종료를 요청하고 최대 5초 기다린다. 그래도 떠 있으면 아무것도 바꾸지 않고 실패한다.
# (떠 있지 않을 때는 osascript를 부르지 않는다: 그러면 앱이 새로 실행될 수 있다.)
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
    die "Where Was I가 5초 안에 종료되지 않았어요. 직접 종료한 뒤 다시 실행해 주세요. (아무것도 바꾸지 않았어요)" \
        "Where Was I is still running 5 s after the quit request; quit it and run this again (nothing was replaced)."
  fi
}

# 훅 설치를 할지 정한다. 0이면 설치.
want_hooks() {
  if [ "$YES" = 1 ]; then return 0; fi
  tty_device="${WWI_TTY:-/dev/tty}"
  # curl | sh 에서는 표준 입력이 스크립트 자신이라 터미널(/dev/tty)에서 읽는다. 터미널이 없으면 묻지 않는다.
  if ! ( : < "$tty_device" ) 2>/dev/null; then
    note "대화형 터미널이 없어서 Claude Code/Codex 훅 설치는 건너뛰었어요. (--yes 로 설치할 수 있어요)" \
         "No interactive terminal, so the Claude Code/Codex hooks were not installed (use --yes to install them)."
    return 1
  fi
  printf 'Claude Code/Codex 훅을 설치할까요? [y/N] (Install Claude Code/Codex hooks?) '
  answer=""
  IFS= read -r answer < "$tty_device" || answer=""
  case "$answer" in y|Y|yes|YES|Yes) return 0 ;; esac
  return 1
}

install_hooks() {
  link="$1"
  only=""
  if [ -d "$HOME/.claude" ] && [ -d "$HOME/.codex" ]; then only=""
  elif [ -d "$HOME/.claude" ]; then only="claude"
  elif [ -d "$HOME/.codex" ]; then only="codex"
  else
    note "~/.claude 와 ~/.codex 가 없어서 훅은 설치하지 않았어요." \
         "Neither ~/.claude nor ~/.codex exists, so no hooks were installed."
    return 0
  fi
  say "Claude Code/Codex 훅을 설치해요" "Installing Claude Code/Codex hooks (backups are kept)"
  # 훅이 부를 경로는 앱 안의 실제 경로가 아니라 늘 ~/.local/bin/wwi 이다(앱을 업데이트해도 그대로).
  if [ -n "$only" ]; then
    "$link" hooks install --only "$only" --claude-settings "$HOME/.claude/settings.json" \
      --codex-hooks "$HOME/.codex/hooks.json" --wwi-path "$link" \
      || warn "훅 설치에 실패했어요. 문제를 고친 뒤 다시 실행해 주세요: wwi hooks install" \
              "Hook installation failed; fix the problem and run: wwi hooks install"
  else
    "$link" hooks install --claude-settings "$HOME/.claude/settings.json" \
      --codex-hooks "$HOME/.codex/hooks.json" --wwi-path "$link" \
      || warn "훅 설치에 실패했어요. 문제를 고친 뒤 다시 실행해 주세요: wwi hooks install" \
              "Hook installation failed; fix the problem and run: wwi hooks install"
  fi
  return 0
}

# 0.1.x(JTM) 훅이 설정 파일에 남아 있는가(0이면 있음). HookConfig.isLegacy 와 같은 규칙: 그 에이전트 파일에서
# 절대 경로 + ` ingest <agent> ` + 끝의 `# jtm-managed`(claude 파일엔 claude, codex 파일엔 codex).
# 경로 이름은 보지 않는다(`--jtm-path /opt/x/jtm-dev` 로 직접 지정한 것도 센다).
has_legacy_hooks() {
  if [ -f "$HOME/.claude/settings.json" ] && grep -q "['\"]/[^\"]* ingest claude # jtm-managed" "$HOME/.claude/settings.json" 2>/dev/null; then return 0; fi
  if [ -f "$HOME/.codex/hooks.json" ] && grep -q "['\"]/[^\"]* ingest codex # jtm-managed" "$HOME/.codex/hooks.json" 2>/dev/null; then return 0; fi
  return 1
}

# 옛 ~/.local/bin/jtm 이 우리 링크인가: 앱 번들 안의 CLI(*/Contents/Helpers/jtm)를 가리키거나, 훅 이전에 실패했을 때
# 우리가 새 앱의 CLI(*/Contents/Helpers/wwi)로 돌려 놓은 것. 직접 만든 jtm 은 우리 것이 아니다.
is_legacy_link() {
  [ -L "$1" ] || return 1
  case "$(readlink "$1")" in */Contents/Helpers/jtm|*/Contents/Helpers/wwi) return 0 ;; esac
  return 1
}

# 링크를 대상만 바꿔서 제자리에서 교체한다(임시 링크를 만든 뒤 rename: 링크가 없는 순간이 없다).
repoint_link() {
  repoint_tmp="$1.repoint.$$"
  rm -f "$repoint_tmp"
  ln -s "$2" "$repoint_tmp" && mv -f "$repoint_tmp" "$1" || { rm -f "$repoint_tmp"; return 1; }
}

# 옛 이름의 앱(JTM.app)을 지운다. 지우지 못해도 설치는 계속한다.
remove_old_app() {
  rm -rf "$1" || { warn "$1 를 지우지 못했어요. 같은 앱의 옛 이름이니 직접 지워 주세요." "Could not remove $1; it is the old name of this app, please delete it yourself."; return 0; }
  say "옛 JTM.app 을 지웠어요" "Removed the old $1 (this app was called JTM before)"
}

usage() {
  cat <<'USAGE'
Where Was I installer / Where Was I 설치 스크립트

  curl -fsSL https://raw.githubusercontent.com/hiphapis/where-was-i/main/scripts/install.sh | sh
  curl -fsSL https://raw.githubusercontent.com/hiphapis/where-was-i/main/scripts/install.sh | sh -s -- --yes

Options:
  --yes, -y         install the Claude Code/Codex hooks without asking (same as WWI_YES=1)
  --version X.Y.Z   install a specific version (same as WWI_VERSION)
  -h, --help        show this help
Environment: WWI_VERSION, WWI_INSTALL_DIR (default ~/Applications), WWI_YES, WWI_REPO
Upgrading from JTM (0.1.x) is handled: the old app, the old jtm link and the old hooks are replaced.
USAGE
}

cleanup() { if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then rm -rf "$WORK_DIR"; fi; }

main() {
  set -eu
  REPO="${WWI_REPO:-hiphapis/where-was-i}"
  INSTALL_DIR="${WWI_INSTALL_DIR:-$HOME/Applications}"
  VERSION="${WWI_VERSION:-}"
  YES=0
  if [ "${WWI_YES:-}" = 1 ]; then YES=1; fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes|-y) YES=1 ;;
      --version) [ "$#" -ge 2 ] || die "--version 에 값이 필요해요 / --version needs a value"; VERSION="$2"; shift ;;
      --version=*) VERSION="${1#--version=}" ;;
      -h|--help) usage; return 0 ;;
      *) die "알 수 없는 옵션: $1 / unknown option: $1" ;;
    esac
    shift
  done

  # --- 환경 확인 -------------------------------------------------------------
  [ "$(uname -s)" = Darwin ] || die "macOS에서만 설치할 수 있어요." "Where Was I runs on macOS only."
  macos_major="$(sw_vers -productVersion | cut -d. -f1)"
  case "$macos_major" in ''|*[!0-9]*) die "macOS 버전을 알 수 없어요." "Cannot read the macOS version." ;; esac
  [ "$macos_major" -ge 14 ] || die "macOS 14 이상이 필요해요 (지금: $(sw_vers -productVersion))." \
                                   "macOS 14 or newer is required (this is $(sw_vers -productVersion))."
  case "$(uname -m)" in
    arm64|x86_64) ;;
    *) die "지원하지 않는 CPU예요: $(uname -m)" "Unsupported architecture: $(uname -m) (arm64 and x86_64 only)." ;;
  esac
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME 이 올바르지 않아요." "HOME is not set to a directory."
  for tool in curl shasum ditto; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool 을(를) 찾을 수 없어요." "Required tool not found: $tool"
  done

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wwi-install.XXXXXX")"
  trap cleanup EXIT
  trap 'cleanup; exit 130' INT TERM HUP

  # --- 버전과 주소 -----------------------------------------------------------
  if [ -n "${WWI_RELEASE_URL:-}" ]; then
    base="${WWI_RELEASE_URL%/}"
    if [ -z "$VERSION" ]; then
      VERSION="$(curl -fsSL "$base/VERSION" | tr -d '[:space:]')" \
        || die "버전을 알 수 없어요: $base/VERSION" "Cannot read the version from $base/VERSION"
    fi
  else
    if [ -z "$VERSION" ]; then
      say "최신 버전을 확인해요" "Looking up the latest release of $REPO"
      release_json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/releases/latest")" \
        || die "최신 릴리스를 가져오지 못했어요. 네트워크를 확인하거나 WWI_VERSION=X.Y.Z 로 지정해 주세요." \
               "Could not fetch the latest release; check the network or set WWI_VERSION=X.Y.Z."
      VERSION="$(printf '%s' "$release_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    fi
    VERSION="${VERSION#v}"
    base="https://github.com/$REPO/releases/download/v$VERSION"
  fi
  VERSION="${VERSION#v}"
  printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$' \
    || die "올바르지 않은 버전이에요: '$VERSION'" "Not a valid version: '$VERSION'"
  zip_name="WhereWasI-$VERSION.zip"

  # --- 내려받기와 확인 --------------------------------------------------------
  say "Where Was I $VERSION 을(를) 내려받아요" "Downloading $zip_name"
  curl -fsSL --retry 2 -o "$WORK_DIR/$zip_name" "$base/$zip_name" \
    || die "$zip_name 을(를) 내려받지 못했어요: $base/$zip_name" "Download failed: $base/$zip_name"
  curl -fsSL --retry 2 -o "$WORK_DIR/$zip_name.sha256" "$base/$zip_name.sha256" \
    || die "체크섬 파일을 내려받지 못했어요: $base/$zip_name.sha256" "Checksum download failed: $base/$zip_name.sha256"

  expected="$(awk 'NR==1 {print $1}' "$WORK_DIR/$zip_name.sha256")"
  printf '%s' "$expected" | grep -Eq '^[0-9a-fA-F]{64}$' \
    || die "체크섬 파일 형식이 올바르지 않아요." "The .sha256 file is malformed."
  actual="$(shasum -a 256 "$WORK_DIR/$zip_name" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    die "체크섬이 달라요. 설치하지 않았어요. (받은 값 $actual, 기대 값 $expected)" \
        "Checksum mismatch; nothing was installed (got $actual, expected $expected)."
  fi
  note "체크섬 확인 완료 / checksum OK"

  mkdir "$WORK_DIR/extract"
  ditto -x -k "$WORK_DIR/$zip_name" "$WORK_DIR/extract" || die "압축을 풀지 못했어요." "Could not unzip $zip_name."
  src="$WORK_DIR/extract/Where Was I.app"
  [ -f "$src/Contents/Info.plist" ] || die "받은 파일에 Where Was I.app 이 없어요." "The archive does not contain Where Was I.app."
  [ -x "$src/Contents/Helpers/wwi" ] || die "받은 앱에 내장 wwi 가 없어요." "The app does not contain Contents/Helpers/wwi."
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$src/Contents/Info.plist" 2>/dev/null || true)"
  [ -n "$bundle_id" ] || die "앱의 번들 ID를 읽지 못했어요." "Cannot read the app's bundle identifier."
  if command -v codesign >/dev/null 2>&1; then
    codesign --verify --deep --strict "$src" 2>/dev/null \
      || die "앱의 서명이 올바르지 않아요." "The app's code signature is invalid."
  fi

  # --- 교체 -------------------------------------------------------------------
  quit_app "$bundle_id"
  dest="$INSTALL_DIR/Where Was I.app"
  say "$dest 에 설치해요" "Installing to $dest"
  mkdir -p "$INSTALL_DIR"
  # 임시 위치에 먼저 복사해서, 복사가 실패해도 설치돼 있던 앱이 사라지지 않게 한다.
  rm -rf "$dest.new" "$dest.old"
  ditto "$src" "$dest.new" || die "앱을 복사하지 못했어요." "Could not copy the app into $INSTALL_DIR."
  if [ -e "$dest" ]; then mv "$dest" "$dest.old"; fi
  mv "$dest.new" "$dest"
  rm -rf "$dest.old"
  # curl 로 받으면 격리 표시가 붙지 않지만, 혹시 있으면 방어적으로 지운다.
  xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

  # --- CLI 링크 -----------------------------------------------------------------
  link_dir="$HOME/.local/bin"
  link="$link_dir/wwi"
  legacy_link="$link_dir/jtm"
  mkdir -p "$link_dir"
  if [ -d "$link" ] && [ ! -L "$link" ]; then die "$link 가 폴더예요. 옮긴 뒤 다시 실행해 주세요." "$link is a directory."; fi
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    backup="$link.wwi-backup-$(date +%Y%m%d-%H%M%S)"
    mv "$link" "$backup"
    note "기존 $link 파일은 $backup 로 옮겼어요." "Moved the existing file to $backup"
  fi
  ln -sfn "$dest/Contents/Helpers/wwi" "$link"
  say "$link → $dest/Contents/Helpers/wwi" "CLI linked"
  case ":${PATH:-}:" in
    *":$link_dir:"*) ;;
    *) warn "$link_dir 가 PATH에 없어요. 셸 설정에 추가하세요: export PATH=\"\$HOME/.local/bin:\$PATH\"" \
            "$link_dir is not on your PATH; add: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac

  # --- 훅 --------------------------------------------------------------------------
  # 옛 훅(`# jtm-managed`)이 있으면 이미 쓰고 있던 것이라 묻지 않고 새 항목으로 바꾼다. 그렇지 않으면 평소처럼 물어본다.
  if has_legacy_hooks; then
    say "옛 jtm 훅을 wwi 훅으로 바꿔요" "Migrating the old jtm hooks to wwi"
    install_hooks "$link"
  elif want_hooks; then
    install_hooks "$link"
  fi

  # --- 옛 이름(JTM 0.1.x)의 앱과 CLI 링크 ----------------------------------------------------
  # 새 앱·wwi 링크·훅 이전이 끝난 다음에만 옛 것을 치운다. 어느 시점에도 옛 `# jtm-managed` 훅이 없는 파일을 부르면 안 된다.
  # 번들 ID가 같아서 JTM.app 을 남겨 두면 메뉴바 아이콘이 둘이 된다.
  keep_old_apps=0
  if has_legacy_hooks; then
    # 훅을 새 항목으로 못 바꿨다(설정 파일 오류 등): 옛 훅이 아직 ~/.local/bin/jtm 을 부른다. 그 링크를 새 앱의 CLI 로 돌려
    # 놓으면 옛 훅도 계속 동작한다(`wwi ingest <agent>` 는 같은 인자를 받는다). 돌리지 못하면 옛 앱도 지우지 않는다.
    if is_legacy_link "$legacy_link"; then
      if repoint_link "$legacy_link" "$dest/Contents/Helpers/wwi"; then
        warn "옛 jtm 훅이 아직 남아 있어서 $legacy_link 를 새 앱의 CLI 로 돌려 놓았어요. 문제를 고친 뒤 wwi hooks install 을 실행하세요." \
             "Old jtm hooks are still installed, so $legacy_link now points at the new CLI and keeps working; fix the problem and run: wwi hooks install"
      else
        keep_old_apps=1
        warn "옛 jtm 훅이 아직 남아 있고 $legacy_link 를 돌려 놓지 못해서 옛 JTM.app 을 지우지 않았어요. 문제를 고친 뒤 wwi hooks install 을 실행하세요." \
             "Old jtm hooks are still installed and $legacy_link could not be repointed, so the old JTM.app was kept; fix the problem and run: wwi hooks install"
      fi
    else
      # 옛 훅이 링크가 아닌 경로(예: JTM.app 안의 helper)를 직접 부를 수 있다. 그 대상을 살려 두려고 옛 앱도 남긴다.
      keep_old_apps=1
      warn "옛 jtm 훅이 아직 남아 있어서 옛 JTM.app 을 지우지 않았어요. 문제를 고친 뒤 wwi hooks install 을 실행하세요." \
           "Old jtm hooks are still installed, so the old JTM.app was kept; fix the problem and run: wwi hooks install"
    fi
  fi
  if [ "$keep_old_apps" = 0 ]; then
    # 같은 폴더가 두 번 나와도(INSTALL_DIR 가 ~/Applications 일 때) 처음에 지워지므로 두 번째는 건너뛴다.
    for old_app in "$INSTALL_DIR/JTM.app" "$HOME/Applications/JTM.app" /Applications/JTM.app; do
      if [ -d "$old_app" ]; then
        quit_app "$bundle_id"   # 다른 폴더의 옛 앱이 떠 있을 수도 있다(번들 ID가 같다). 이미 종료했으면 아무것도 하지 않는다.
        remove_old_app "$old_app"
      fi
    done
  fi
  if ! has_legacy_hooks && is_legacy_link "$legacy_link"; then
    rm -f "$legacy_link"
    say "옛 $legacy_link 링크를 지웠어요" "Removed the old jtm link"
  fi

  # --- 실행 --------------------------------------------------------------------------
  say "Where Was I를 열어요" "Opening Where Was I"
  open "$dest" || warn "앱을 열지 못했어요. 직접 열어 주세요: open \"$dest\"" "Could not open the app; run: open \"$dest\""
  say "설치 완료: Where Was I $VERSION" "Done. Where Was I $VERSION is installed. Uninstall: curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/uninstall.sh | sh"
}

main "$@"
