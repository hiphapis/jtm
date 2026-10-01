#!/bin/sh
# JTM 설치 스크립트 / JTM installer (macOS 14+, Apple Silicon and Intel).
#
#   curl -fsSL https://raw.githubusercontent.com/hiphapis/jtm/main/scripts/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/hiphapis/jtm/main/scripts/install.sh | sh -s -- --yes
#
# 하는 일 / What it does:
#   1. GitHub Releases에서 JTM-<version>.zip 과 .sha256 을 받아 체크섬을 확인한다.
#   2. 실행 중인 JTM을 종료하고 ~/Applications/JTM.app 을 교체한다.
#   3. ~/.local/bin/jtm 을 앱 안의 CLI(JTM.app/Contents/Helpers/jtm)로 연결한다.
#   4. 물어본 뒤(또는 --yes) Claude Code / Codex 훅을 설치한다(`jtm hooks install`, 백업을 남긴다).
#   5. 앱을 `open`으로 연다. 앱 안의 실행 파일을 직접 실행하지 않는다.
#
# 옵션 / Options:        --yes, -y        훅 설치를 묻지 않고 진행 (JTM_YES=1 과 같다)
#                        --version X.Y.Z  특정 버전 (JTM_VERSION 과 같다)
# 환경 변수 / Environment:
#   JTM_VERSION       설치할 버전(기본: 최신 릴리스)
#   JTM_INSTALL_DIR   앱을 둘 폴더(기본: ~/Applications)
#   JTM_YES=1         훅 설치 질문을 건너뛰고 설치
#   JTM_REPO          GitHub 저장소(기본: hiphapis/jtm)
#   JTM_RELEASE_URL   테스트용: JTM-<version>.zip 과 .sha256 이 있는 폴더 주소(file:// 포함). 설정하면 GitHub API를 부르지 않는다.
#   JTM_TTY           테스트용: 질문에 답을 읽을 장치(기본: /dev/tty)
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
  say "실행 중인 JTM을 종료해요" "Quitting the running JTM ($1)"
  osascript -e "tell application id \"$1\" to quit" >/dev/null 2>&1 &
  quit_pid=$!
  waited=0
  while app_running "$1" && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  kill "$quit_pid" 2>/dev/null || true
  wait "$quit_pid" 2>/dev/null || true
  if app_running "$1"; then
    die "JTM이 5초 안에 종료되지 않았어요. 직접 종료한 뒤 다시 실행해 주세요. (아무것도 바꾸지 않았어요)" \
        "JTM is still running 5 s after the quit request; quit it and run this again (nothing was replaced)."
  fi
}

# 훅 설치를 할지 정한다. 0이면 설치.
want_hooks() {
  if [ "$YES" = 1 ]; then return 0; fi
  tty_device="${JTM_TTY:-/dev/tty}"
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
  # 훅이 부를 경로는 앱 안의 실제 경로가 아니라 늘 ~/.local/bin/jtm 이다(앱을 업데이트해도 그대로).
  if [ -n "$only" ]; then
    "$link" hooks install --only "$only" --claude-settings "$HOME/.claude/settings.json" \
      --codex-hooks "$HOME/.codex/hooks.json" --jtm-path "$link" \
      || warn "훅 설치에 실패했어요. 문제를 고친 뒤 다시 실행해 주세요: jtm hooks install" \
              "Hook installation failed; fix the problem and run: jtm hooks install"
  else
    "$link" hooks install --claude-settings "$HOME/.claude/settings.json" \
      --codex-hooks "$HOME/.codex/hooks.json" --jtm-path "$link" \
      || warn "훅 설치에 실패했어요. 문제를 고친 뒤 다시 실행해 주세요: jtm hooks install" \
              "Hook installation failed; fix the problem and run: jtm hooks install"
  fi
  return 0
}

usage() {
  cat <<'USAGE'
JTM installer / JTM 설치 스크립트

  curl -fsSL https://raw.githubusercontent.com/hiphapis/jtm/main/scripts/install.sh | sh
  curl -fsSL https://raw.githubusercontent.com/hiphapis/jtm/main/scripts/install.sh | sh -s -- --yes

Options:
  --yes, -y         install the Claude Code/Codex hooks without asking (same as JTM_YES=1)
  --version X.Y.Z   install a specific version (same as JTM_VERSION)
  -h, --help        show this help
Environment: JTM_VERSION, JTM_INSTALL_DIR (default ~/Applications), JTM_YES, JTM_REPO
USAGE
}

cleanup() { if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then rm -rf "$WORK_DIR"; fi; }

main() {
  set -eu
  REPO="${JTM_REPO:-hiphapis/jtm}"
  INSTALL_DIR="${JTM_INSTALL_DIR:-$HOME/Applications}"
  VERSION="${JTM_VERSION:-}"
  YES=0
  if [ "${JTM_YES:-}" = 1 ]; then YES=1; fi

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
  [ "$(uname -s)" = Darwin ] || die "macOS에서만 설치할 수 있어요." "JTM runs on macOS only."
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

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jtm-install.XXXXXX")"
  trap cleanup EXIT
  trap 'cleanup; exit 130' INT TERM HUP

  # --- 버전과 주소 -----------------------------------------------------------
  if [ -n "${JTM_RELEASE_URL:-}" ]; then
    base="${JTM_RELEASE_URL%/}"
    if [ -z "$VERSION" ]; then
      VERSION="$(curl -fsSL "$base/VERSION" | tr -d '[:space:]')" \
        || die "버전을 알 수 없어요: $base/VERSION" "Cannot read the version from $base/VERSION"
    fi
  else
    if [ -z "$VERSION" ]; then
      say "최신 버전을 확인해요" "Looking up the latest release of $REPO"
      release_json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/releases/latest")" \
        || die "최신 릴리스를 가져오지 못했어요. 네트워크를 확인하거나 JTM_VERSION=X.Y.Z 로 지정해 주세요." \
               "Could not fetch the latest release; check the network or set JTM_VERSION=X.Y.Z."
      VERSION="$(printf '%s' "$release_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    fi
    VERSION="${VERSION#v}"
    base="https://github.com/$REPO/releases/download/v$VERSION"
  fi
  VERSION="${VERSION#v}"
  printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$' \
    || die "올바르지 않은 버전이에요: '$VERSION'" "Not a valid version: '$VERSION'"
  zip_name="JTM-$VERSION.zip"

  # --- 내려받기와 확인 --------------------------------------------------------
  say "JTM $VERSION 을(를) 내려받아요" "Downloading $zip_name"
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
  src="$WORK_DIR/extract/JTM.app"
  [ -f "$src/Contents/Info.plist" ] || die "받은 파일에 JTM.app 이 없어요." "The archive does not contain JTM.app."
  [ -x "$src/Contents/Helpers/jtm" ] || die "받은 앱에 내장 jtm 이 없어요." "The app does not contain Contents/Helpers/jtm."
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$src/Contents/Info.plist" 2>/dev/null || true)"
  [ -n "$bundle_id" ] || die "앱의 번들 ID를 읽지 못했어요." "Cannot read the app's bundle identifier."
  if command -v codesign >/dev/null 2>&1; then
    codesign --verify --deep --strict "$src" 2>/dev/null \
      || die "앱의 서명이 올바르지 않아요." "The app's code signature is invalid."
  fi

  # --- 교체 -------------------------------------------------------------------
  quit_app "$bundle_id"
  dest="$INSTALL_DIR/JTM.app"
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
  link="$link_dir/jtm"
  mkdir -p "$link_dir"
  if [ -d "$link" ] && [ ! -L "$link" ]; then die "$link 가 폴더예요. 옮긴 뒤 다시 실행해 주세요." "$link is a directory."; fi
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    backup="$link.jtm-backup-$(date +%Y%m%d-%H%M%S)"
    mv "$link" "$backup"
    note "기존 $link 파일은 $backup 로 옮겼어요." "Moved the existing file to $backup"
  fi
  ln -sfn "$dest/Contents/Helpers/jtm" "$link"
  say "$link → $dest/Contents/Helpers/jtm" "CLI linked"
  case ":${PATH:-}:" in
    *":$link_dir:"*) ;;
    *) warn "$link_dir 가 PATH에 없어요. 셸 설정에 추가하세요: export PATH=\"\$HOME/.local/bin:\$PATH\"" \
            "$link_dir is not on your PATH; add: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac

  # --- 훅 --------------------------------------------------------------------------
  if want_hooks; then install_hooks "$link"; fi

  # --- 실행 --------------------------------------------------------------------------
  say "JTM을 열어요" "Opening JTM"
  open "$dest" || warn "앱을 열지 못했어요. 직접 열어 주세요: open \"$dest\"" "Could not open the app; run: open \"$dest\""
  say "설치 완료: JTM $VERSION" "Done. JTM $VERSION is installed. Uninstall: curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/uninstall.sh | sh"
}

main "$@"
