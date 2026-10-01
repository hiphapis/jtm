#!/usr/bin/env bash
# install.sh / uninstall.sh 를 임시 HOME 과 로컬 릴리스 폴더(file://)로 끝까지 돌려 본다.
#   scripts/test-install-scripts.sh [path/to/JTM-<version>.zip]
# zip 을 주지 않으면 dist/JTM-<VERSION>.zip 을 쓰고, 없으면 `build-app.sh --release` 로 만든다.
# 진짜 앱은 띄우지도 종료하지도 않는다: open/lsappinfo/osascript 는 PATH 앞에 놓은 가짜이고,
# 진짜 ~/.claude/settings.json 과 ~/.codex/hooks.json 은 시작과 끝의 해시로 바뀌지 않았음을 확인한다.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
REAL_HOME="$HOME"

hash_of() { if [[ -e "$1" ]]; then shasum -a 256 "$1" | cut -d' ' -f1; else echo "absent"; fi; }
REAL_CLAUDE_BEFORE="$(hash_of "$REAL_HOME/.claude/settings.json")"
REAL_CODEX_BEFORE="$(hash_of "$REAL_HOME/.codex/hooks.json")"

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
ZIP="${1:-$ROOT/dist/JTM-$VERSION.zip}"
if [[ ! -f "$ZIP" ]]; then
  echo "building the release zip first"
  scripts/build-app.sh --release >/dev/null
fi
[[ -f "$ZIP" ]] || { echo "FAIL: no zip at $ZIP" >&2; exit 1; }
ZIP_VERSION="$(basename "$ZIP" .zip)"; ZIP_VERSION="${ZIP_VERSION#JTM-}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jtm-installer-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
T="$WORK/home"; STUBS="$WORK/bin"; STATE="$WORK/state"; REL="$WORK/release"
mkdir -p "$T" "$STUBS" "$STATE" "$REL"
[[ "$T" != "$REAL_HOME" ]] || { echo "FAIL: temp home is the real home" >&2; exit 1; }

# 로컬 릴리스: zip + sha256 + VERSION.
cp "$ZIP" "$REL/JTM-$ZIP_VERSION.zip"
(cd "$REL" && shasum -a 256 "JTM-$ZIP_VERSION.zip" > "JTM-$ZIP_VERSION.zip.sha256")
echo "$ZIP_VERSION" > "$REL/VERSION"

# 가짜 시스템 도구.
cat > "$STUBS/open" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_STATE/open.log"
STUB
cat > "$STUBS/lsappinfo" <<'STUB'
#!/bin/sh
[ -e "$STUB_STATE/running" ] && echo 'ASN:0x0-0x1:'
exit 0
STUB
cat > "$STUBS/osascript" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_STATE/osascript.log"
if [ "${STUB_QUIT_WORKS:-0}" = 1 ]; then sleep 0.3; rm -f "$STUB_STATE/running"; fi
exit 0
STUB
chmod +x "$STUBS/open" "$STUBS/lsappinfo" "$STUBS/osascript"

APPS="$T/Applications"
LOG="$WORK/out.log"
fail() { echo "FAIL: $1" >&2; sed 's/^/  | /' "$LOG" | tail -25 >&2; exit 1; }
# 환경을 통째로 바꿔서 돌린다. TERM 이 없어도 되고, 진짜 HOME 은 보이지 않는다.
run() {
  local script="$1"; shift
  env -i HOME="$T" PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" STUB_STATE="$STATE" \
    JTM_INSTALL_DIR="$APPS" JTM_RELEASE_URL="file://$REL" ${EXTRA_ENV:-} \
    sh "$ROOT/scripts/$script" "$@" >"$LOG" 2>&1 </dev/null
}
reset_home() { rm -rf "$T" "$STATE"/*; mkdir -p "$T/.claude" "$T/.codex"; }
settings_json='{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}'

echo "1) bad checksum: aborts, nothing installed"
reset_home
cp "$REL/JTM-$ZIP_VERSION.zip.sha256" "$WORK/good.sha256"
echo "0000000000000000000000000000000000000000000000000000000000000000  JTM-$ZIP_VERSION.zip" > "$REL/JTM-$ZIP_VERSION.zip.sha256"
if run install.sh --yes; then fail "install succeeded with a bad checksum"; fi
grep -q "체크섬이 달라요" "$LOG" || fail "no checksum error message"
[[ ! -e "$APPS/JTM.app" && ! -e "$T/.local/bin/jtm" && ! -e "$STATE/open.log" ]] || fail "something was installed anyway"
cp "$WORK/good.sha256" "$REL/JTM-$ZIP_VERSION.zip.sha256"

echo "2) no terminal and no --yes: app + CLI link are installed, hooks are skipped with a message"
reset_home
printf '%s' "$settings_json" > "$T/.claude/settings.json"
run install.sh || fail "install failed"
[[ -x "$APPS/JTM.app/Contents/Helpers/jtm" ]] || fail "app not installed"
[[ "$(readlink "$T/.local/bin/jtm")" == "$APPS/JTM.app/Contents/Helpers/jtm" ]] || fail "CLI link is wrong"
grep -q "훅 설치는 건너뛰었어요" "$LOG" || fail "no skip message"
[[ "$(cat "$T/.claude/settings.json")" == "$settings_json" && ! -e "$T/.codex/hooks.json" ]] || fail "hooks were written without consent"
grep -qx "$APPS/JTM.app" "$STATE/open.log" || fail "the app was not opened with \`open\`"
[[ -z "$(xattr -r "$APPS/JTM.app" 2>/dev/null | grep quarantine || true)" ]] || fail "quarantine attribute present"
"$T/.local/bin/jtm" --help >/dev/null || fail "the linked CLI does not run"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APPS/JTM.app/Contents/Info.plist")" == "${ZIP_VERSION%%-*}" ]] || fail "version in Info.plist"

echo "3) --yes: hooks go into the temp HOME only, with the stable ~/.local/bin/jtm path and a backup"
run install.sh --yes || fail "install --yes failed"
grep -q "jtm ingest\|ingest" "$T/.claude/settings.json" || fail "claude hooks missing"
grep -q "echo mine" "$T/.claude/settings.json" && grep -q '"theme"' "$T/.claude/settings.json" || fail "user settings were lost"
grep -q "$T/.local/bin/jtm" "$T/.claude/settings.json" || fail "hook does not call ~/.local/bin/jtm"
! grep -q "Contents/Helpers" "$T/.claude/settings.json" || fail "hook points into the bundle"
grep -q "$T/.local/bin/jtm" "$T/.codex/hooks.json" || fail "codex hooks missing"
ls "$T/.claude" | grep -q "settings.json.jtm-backup-" || fail "no backup of settings.json"
grep -q "Trust all" "$LOG" || fail "no Codex trust notice"
# --jtm-path 없이: 링크로 실행한 jtm 의 기본 경로가 설치 스크립트가 쓴 경로와 같아야 한다(stale-path 가 나오면 안 된다).
status_json="$(env HOME="$T" "$T/.local/bin/jtm" hooks status --json --claude-settings "$T/.claude/settings.json" --codex-hooks "$T/.codex/hooks.json")"
if grep -q '"stale-path"\|"missing"' <<<"$status_json"; then fail "hooks status is not all installed"; fi
grep -q "\"jtmPath\" : \"$T/.local/bin/jtm\"" <<<"$status_json" || fail "default jtm path is not ~/.local/bin/jtm"
if [[ -n "${VERBOSE:-}" ]]; then echo "   --- install.sh --yes output ---"; sed 's/^/   | /' "$LOG"; fi
echo "   resulting files:"
( cd "$T" && find . -not -path './Applications/JTM.app/*' \( -type f -o -type l \) | sort | sed 's/^/     /' )
echo "     (Applications/JTM.app/... $(find "$APPS/JTM.app" -type f | wc -l | tr -d ' ') files)"

echo "4) upgrade over an installed app: replaced, hooks reported as already installed, nothing left behind"
: > "$APPS/JTM.app/OLD_MARKER"
before="$(ls "$T/.claude" | wc -l | tr -d ' ')"
run install.sh --yes || fail "re-install failed"
[[ ! -e "$APPS/JTM.app/OLD_MARKER" && ! -e "$APPS/JTM.app.new" && ! -e "$APPS/JTM.app.old" ]] || fail "app not cleanly replaced"
[[ "$(ls "$T/.claude" | wc -l | tr -d ' ')" == "$before" ]] || fail "re-install created another backup"

echo "5) interactive answer from the terminal device (JTM_TTY): y installs hooks, n does not"
reset_home; echo y > "$WORK/tty"
EXTRA_ENV="JTM_TTY=$WORK/tty" run install.sh || fail "install with tty y failed"
grep -q "$T/.local/bin/jtm" "$T/.claude/settings.json" || fail "answer y did not install hooks"
reset_home; echo n > "$WORK/tty"
EXTRA_ENV="JTM_TTY=$WORK/tty" run install.sh || fail "install with tty n failed"
[[ ! -e "$T/.claude/settings.json" ]] || fail "answer n installed hooks anyway"

echo "6) a running JTM is quit by bundle id before the swap; one that never quits aborts without replacing"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPS/JTM.app/Contents/Info.plist")"
touch "$STATE/running"; : > "$APPS/JTM.app/OLD_MARKER"
EXTRA_ENV="STUB_QUIT_WORKS=1" run install.sh || fail "install failed although the app quit"
grep -q "tell application id \"$bundle_id\" to quit" "$STATE/osascript.log" || fail "quit was not requested by bundle id"
[[ ! -e "$APPS/JTM.app/OLD_MARKER" ]] || fail "app not replaced"
touch "$STATE/running"; : > "$APPS/JTM.app/KEEP_MARKER"
if run install.sh; then fail "install succeeded although the app kept running"; fi
grep -q "still running" "$LOG" || fail "no loud error"
[[ -e "$APPS/JTM.app/KEEP_MARKER" ]] || fail "the installed app was replaced anyway"
rm -f "$STATE/running"

echo "7) uninstall without --yes and without a terminal refuses and removes nothing"
reset_home
printf '%s' "$settings_json" > "$T/.claude/settings.json"
run install.sh --yes || fail "install failed"
mkdir -p "$T/Library/Application Support/jtm" "$T/Library/Logs/jtm"
echo db > "$T/Library/Application Support/jtm/jtm.sqlite"; echo log > "$T/Library/Logs/jtm/app.log"
if run uninstall.sh; then fail "uninstall ran without confirmation"; fi
[[ -e "$APPS/JTM.app" && -L "$T/.local/bin/jtm" ]] || fail "uninstall removed things without confirmation"
echo n > "$WORK/tty"
EXTRA_ENV="JTM_TTY=$WORK/tty" run uninstall.sh || fail "declining should not be an error"
[[ -e "$APPS/JTM.app" ]] || fail "declined uninstall removed the app"

echo "8) uninstall --yes: hooks out (user settings stay), link and app gone, data kept"
run uninstall.sh --yes || fail "uninstall failed"
[[ ! -e "$APPS/JTM.app" && ! -e "$T/.local/bin/jtm" && ! -L "$T/.local/bin/jtm" ]] || fail "app or link left"
! grep -q "$T/.local/bin/jtm" "$T/.claude/settings.json" || fail "claude hooks left"
grep -q "echo mine" "$T/.claude/settings.json" || fail "user hook removed"
[[ ! -e "$T/.codex/hooks.json" ]] || ! grep -q "ingest" "$T/.codex/hooks.json" || fail "codex hooks left"
[[ -f "$T/Library/Application Support/jtm/jtm.sqlite" && -f "$T/Library/Logs/jtm/app.log" ]] || fail "data was deleted without --purge"
if [[ -n "${VERBOSE:-}" ]]; then echo "   --- uninstall.sh --yes output ---"; sed 's/^/   | /' "$LOG"; fi

echo "9) uninstall --yes --purge deletes the database and logs; a foreign jtm is left alone"
run install.sh --yes || fail "install failed"
rm -f "$T/.local/bin/jtm"; echo "#!/bin/sh" > "$T/.local/bin/jtm"; chmod +x "$T/.local/bin/jtm"   # 직접 만든 jtm
run uninstall.sh --yes --purge || fail "uninstall --purge failed"
[[ -f "$T/.local/bin/jtm" && ! -e "$APPS/JTM.app" ]] || fail "foreign jtm was removed or app left"
[[ ! -e "$T/Library/Application Support/jtm" && ! -e "$T/Library/Logs/jtm" ]] || fail "purge left data"

echo "10) the real hook files were never touched"
[[ "$(hash_of "$REAL_HOME/.claude/settings.json")" == "$REAL_CLAUDE_BEFORE" ]] || fail "real ~/.claude/settings.json changed"
[[ "$(hash_of "$REAL_HOME/.codex/hooks.json")" == "$REAL_CODEX_BEFORE" ]] || fail "real ~/.codex/hooks.json changed"

echo "OK: install.sh / uninstall.sh end to end against a temp HOME (zip: $ZIP_VERSION)"
