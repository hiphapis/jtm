#!/usr/bin/env bash
# install.sh / uninstall.sh 를 임시 HOME 과 로컬 릴리스 폴더(file://)로 끝까지 돌려 본다.
#   scripts/test-install-scripts.sh [path/to/WhereWasI-<version>.zip]
# zip 을 주지 않으면 dist/WhereWasI-<VERSION>.zip 을 쓰고, 없으면 `build-app.sh --release` 로 만든다.
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
ZIP="${1:-$ROOT/dist/WhereWasI-$VERSION.zip}"
if [[ ! -f "$ZIP" ]]; then
  echo "building the release zip first"
  scripts/build-app.sh --release >/dev/null
fi
[[ -f "$ZIP" ]] || { echo "FAIL: no zip at $ZIP" >&2; exit 1; }
ZIP_VERSION="$(basename "$ZIP" .zip)"; ZIP_VERSION="${ZIP_VERSION#WhereWasI-}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wwi-installer-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
T="$WORK/home"; STUBS="$WORK/bin"; STATE="$WORK/state"; REL="$WORK/release"
mkdir -p "$T" "$STUBS" "$STATE" "$REL"
[[ "$T" != "$REAL_HOME" ]] || { echo "FAIL: temp home is the real home" >&2; exit 1; }

# 로컬 릴리스: zip + sha256 + VERSION.
cp "$ZIP" "$REL/WhereWasI-$ZIP_VERSION.zip"
(cd "$REL" && shasum -a 256 "WhereWasI-$ZIP_VERSION.zip" > "WhereWasI-$ZIP_VERSION.zip.sha256")
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
    WWI_INSTALL_DIR="$APPS" WWI_RELEASE_URL="file://$REL" ${EXTRA_ENV:-} \
    sh "$ROOT/scripts/$script" "$@" >"$LOG" 2>&1 </dev/null
}
reset_home() { rm -rf "$T" "$STATE"/*; mkdir -p "$T/.claude" "$T/.codex"; }
settings_json='{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}'

echo "1) bad checksum: aborts, nothing installed"
reset_home
cp "$REL/WhereWasI-$ZIP_VERSION.zip.sha256" "$WORK/good.sha256"
echo "0000000000000000000000000000000000000000000000000000000000000000  WhereWasI-$ZIP_VERSION.zip" > "$REL/WhereWasI-$ZIP_VERSION.zip.sha256"
if run install.sh --yes; then fail "install succeeded with a bad checksum"; fi
grep -q "체크섬이 달라요" "$LOG" || fail "no checksum error message"
[[ ! -e "$APPS/Where Was I.app" && ! -e "$T/.local/bin/wwi" && ! -e "$STATE/open.log" ]] || fail "something was installed anyway"
cp "$WORK/good.sha256" "$REL/WhereWasI-$ZIP_VERSION.zip.sha256"

echo "2) no terminal and no --yes: app + CLI link are installed, hooks are skipped with a message"
reset_home
printf '%s' "$settings_json" > "$T/.claude/settings.json"
run install.sh || fail "install failed"
[[ -x "$APPS/Where Was I.app/Contents/Helpers/wwi" ]] || fail "app not installed"
[[ "$(readlink "$T/.local/bin/wwi")" == "$APPS/Where Was I.app/Contents/Helpers/wwi" ]] || fail "CLI link is wrong"
grep -q "훅 설치는 건너뛰었어요" "$LOG" || fail "no skip message"
[[ "$(cat "$T/.claude/settings.json")" == "$settings_json" && ! -e "$T/.codex/hooks.json" ]] || fail "hooks were written without consent"
grep -qx "$APPS/Where Was I.app" "$STATE/open.log" || fail "the app was not opened with \`open\`"
[[ -z "$(xattr -r "$APPS/Where Was I.app" 2>/dev/null | grep quarantine || true)" ]] || fail "quarantine attribute present"
"$T/.local/bin/wwi" --help >/dev/null || fail "the linked CLI does not run"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APPS/Where Was I.app/Contents/Info.plist")" == "${ZIP_VERSION%%-*}" ]] || fail "version in Info.plist"

echo "3) --yes: hooks go into the temp HOME only, with the stable ~/.local/bin/wwi path and a backup"
run install.sh --yes || fail "install --yes failed"
grep -q "wwi ingest\|ingest" "$T/.claude/settings.json" || fail "claude hooks missing"
grep -q "echo mine" "$T/.claude/settings.json" && grep -q '"theme"' "$T/.claude/settings.json" || fail "user settings were lost"
grep -q "$T/.local/bin/wwi" "$T/.claude/settings.json" || fail "hook does not call ~/.local/bin/wwi"
! grep -q "Contents/Helpers" "$T/.claude/settings.json" || fail "hook points into the bundle"
grep -q "$T/.local/bin/wwi" "$T/.codex/hooks.json" || fail "codex hooks missing"
ls "$T/.claude" | grep -q "settings.json.wwi-backup-" || fail "no backup of settings.json"
grep -q "Trust all" "$LOG" || fail "no Codex trust notice"
# --wwi-path 없이: 링크로 실행한 wwi 의 기본 경로가 설치 스크립트가 쓴 경로와 같아야 한다(stale-path 가 나오면 안 된다).
status_json="$(env HOME="$T" "$T/.local/bin/wwi" hooks status --json --claude-settings "$T/.claude/settings.json" --codex-hooks "$T/.codex/hooks.json")"
if grep -q '"stale-path"\|"missing"' <<<"$status_json"; then fail "hooks status is not all installed"; fi
grep -q "\"wwiPath\" : \"$T/.local/bin/wwi\"" <<<"$status_json" || fail "default wwi path is not ~/.local/bin/wwi"
if [[ -n "${VERBOSE:-}" ]]; then echo "   --- install.sh --yes output ---"; sed 's/^/   | /' "$LOG"; fi
echo "   resulting files:"
( cd "$T" && find . -not -path './Applications/Where Was I.app/*' \( -type f -o -type l \) | sort | sed 's/^/     /' )
echo "     (Applications/Where Was I.app/... $(find "$APPS/Where Was I.app" -type f | wc -l | tr -d ' ') files)"

echo "4) upgrade over an installed app: replaced, hooks reported as already installed, nothing left behind"
: > "$APPS/Where Was I.app/OLD_MARKER"
before="$(ls "$T/.claude" | wc -l | tr -d ' ')"
run install.sh --yes || fail "re-install failed"
[[ ! -e "$APPS/Where Was I.app/OLD_MARKER" && ! -e "$APPS/Where Was I.app.new" && ! -e "$APPS/Where Was I.app.old" ]] || fail "app not cleanly replaced"
[[ "$(ls "$T/.claude" | wc -l | tr -d ' ')" == "$before" ]] || fail "re-install created another backup"

echo "5) interactive answer from the terminal device (WWI_TTY): y installs hooks, n does not"
reset_home; echo y > "$WORK/tty"
EXTRA_ENV="WWI_TTY=$WORK/tty" run install.sh || fail "install with tty y failed"
grep -q "$T/.local/bin/wwi" "$T/.claude/settings.json" || fail "answer y did not install hooks"
reset_home; echo n > "$WORK/tty"
EXTRA_ENV="WWI_TTY=$WORK/tty" run install.sh || fail "install with tty n failed"
[[ ! -e "$T/.claude/settings.json" ]] || fail "answer n installed hooks anyway"

echo "6) a running app is quit by bundle id before the swap; one that never quits aborts without replacing"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPS/Where Was I.app/Contents/Info.plist")"
touch "$STATE/running"; : > "$APPS/Where Was I.app/OLD_MARKER"
EXTRA_ENV="STUB_QUIT_WORKS=1" run install.sh || fail "install failed although the app quit"
grep -q "tell application id \"$bundle_id\" to quit" "$STATE/osascript.log" || fail "quit was not requested by bundle id"
[[ ! -e "$APPS/Where Was I.app/OLD_MARKER" ]] || fail "app not replaced"
touch "$STATE/running"; : > "$APPS/Where Was I.app/KEEP_MARKER"
if run install.sh; then fail "install succeeded although the app kept running"; fi
grep -q "still running" "$LOG" || fail "no loud error"
[[ -e "$APPS/Where Was I.app/KEEP_MARKER" ]] || fail "the installed app was replaced anyway"
rm -f "$STATE/running"

echo "7) uninstall without --yes and without a terminal refuses and removes nothing"
reset_home
printf '%s' "$settings_json" > "$T/.claude/settings.json"
run install.sh --yes || fail "install failed"
mkdir -p "$T/Library/Application Support/jtm" "$T/Library/Logs/jtm"
echo db > "$T/Library/Application Support/jtm/jtm.sqlite"; echo log > "$T/Library/Logs/jtm/app.log"
if run uninstall.sh; then fail "uninstall ran without confirmation"; fi
[[ -e "$APPS/Where Was I.app" && -L "$T/.local/bin/wwi" ]] || fail "uninstall removed things without confirmation"
echo n > "$WORK/tty"
EXTRA_ENV="WWI_TTY=$WORK/tty" run uninstall.sh || fail "declining should not be an error"
[[ -e "$APPS/Where Was I.app" ]] || fail "declined uninstall removed the app"

echo "8) uninstall --yes: hooks out (user settings stay), link and app gone, data kept"
run uninstall.sh --yes || fail "uninstall failed"
[[ ! -e "$APPS/Where Was I.app" && ! -e "$T/.local/bin/wwi" && ! -L "$T/.local/bin/wwi" ]] || fail "app or link left"
! grep -q "$T/.local/bin/wwi" "$T/.claude/settings.json" || fail "claude hooks left"
grep -q "echo mine" "$T/.claude/settings.json" || fail "user hook removed"
[[ ! -e "$T/.codex/hooks.json" ]] || ! grep -q "ingest" "$T/.codex/hooks.json" || fail "codex hooks left"
[[ -f "$T/Library/Application Support/jtm/jtm.sqlite" && -f "$T/Library/Logs/jtm/app.log" ]] || fail "data was deleted without --purge"
if [[ -n "${VERBOSE:-}" ]]; then echo "   --- uninstall.sh --yes output ---"; sed 's/^/   | /' "$LOG"; fi

echo "9) uninstall --yes --purge deletes the database and logs; a foreign wwi is left alone"
run install.sh --yes || fail "install failed"
rm -f "$T/.local/bin/wwi"; echo "#!/bin/sh" > "$T/.local/bin/wwi"; chmod +x "$T/.local/bin/wwi"   # 직접 만든 wwi
run uninstall.sh --yes --purge || fail "uninstall --purge failed"
[[ -f "$T/.local/bin/wwi" && ! -e "$APPS/Where Was I.app" ]] || fail "foreign wwi was removed or app left"
[[ ! -e "$T/Library/Application Support/jtm" && ! -e "$T/Library/Logs/jtm" ]] || fail "purge left data"

# --- JTM(0.1.x)에서 올리기 ----------------------------------------------------------------------------------
# 0.1.x 설치 상태를 임시 HOME 에 흉내 낸다: JTM.app(안의 CLI는 가짜), ~/.local/bin/jtm 링크, `# jtm-managed` 훅.
legacy_cmd() { printf "'%s' ingest %s # jtm-managed" "$T/.local/bin/jtm" "$1"; }
seed_legacy_jtm() {
  reset_home
  mkdir -p "$APPS/JTM.app/Contents/Helpers" "$T/.local/bin"
  printf '#!/bin/sh\necho "$*" >> "%s/jtm.log"\nexit 0\n' "$STATE" > "$APPS/JTM.app/Contents/Helpers/jtm"
  chmod +x "$APPS/JTM.app/Contents/Helpers/jtm"
  ln -s "$APPS/JTM.app/Contents/Helpers/jtm" "$T/.local/bin/jtm"
  cat > "$T/.claude/settings.json" <<JSON
{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]},{"hooks":[{"type":"command","command":"$(legacy_cmd claude)","timeout":5}]}],"SessionStart":[{"hooks":[{"type":"command","command":"$(legacy_cmd claude)","timeout":5}]}]}}
JSON
  cat > "$T/.codex/hooks.json" <<JSON
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$(legacy_cmd codex)","timeout":5}]}]}}
JSON
}
count_of() { grep -o "$1" "$2" | wc -l | tr -d ' '; }
# ~/.local/bin 에 끊어진 링크(대상이 없거나 실행할 수 없는 링크)가 하나도 없다.
no_dangling_links() {
  local f
  for f in "$T/.local/bin"/*; do
    [[ -L "$f" ]] || continue
    [[ -x "$f" ]] || { echo "dangling or non-executable link: $f -> $(readlink "$f")" >&2; return 1; }
  done
  return 0
}
line_of() { grep -n "$1" "$LOG" | head -n 1 | cut -d: -f1; }

echo "9b) upgrade from JTM: running JTM quit, JTM.app and the jtm link replaced, legacy hooks migrated without a prompt"
seed_legacy_jtm
touch "$STATE/running"
EXTRA_ENV="STUB_QUIT_WORKS=1" run install.sh || fail "upgrade install failed"   # --yes 없음, 터미널 없음: 옛 훅은 묻지 않고 바꾼다
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPS/Where Was I.app/Contents/Info.plist")"
grep -q "tell application id \"$bundle_id\" to quit" "$STATE/osascript.log" || fail "the running JTM was not quit by bundle id"
[[ -x "$APPS/Where Was I.app/Contents/Helpers/wwi" ]] || fail "new app not installed"
[[ ! -e "$APPS/JTM.app" ]] || fail "the old JTM.app is still there"
[[ ! -e "$T/.local/bin/jtm" && ! -L "$T/.local/bin/jtm" ]] || fail "the old jtm link is still there"
[[ "$(readlink "$T/.local/bin/wwi")" == "$APPS/Where Was I.app/Contents/Helpers/wwi" ]] || fail "wwi link is wrong"
! grep -q "jtm-managed" "$T/.claude/settings.json" "$T/.codex/hooks.json" || fail "legacy hook entries are still there"
[[ "$(count_of '# wwi-managed' "$T/.claude/settings.json")" == 7 ]] || fail "claude: expected exactly one managed entry per event (7)"
[[ "$(count_of '# wwi-managed' "$T/.codex/hooks.json")" == 5 ]] || fail "codex: expected exactly one managed entry per event (5)"
grep -q "echo mine" "$T/.claude/settings.json" && grep -q '"theme"' "$T/.claude/settings.json" || fail "user settings were lost in the migration"
grep -q "$T/.local/bin/wwi' ingest claude # wwi-managed" "$T/.claude/settings.json" || fail "hook does not call ~/.local/bin/wwi"
ls "$T/.claude" | grep -q "settings.json.wwi-backup-" || fail "no backup of the legacy settings.json"
status_json="$(env HOME="$T" "$T/.local/bin/wwi" hooks status --json --claude-settings "$T/.claude/settings.json" --codex-hooks "$T/.codex/hooks.json")"
if grep -q '"stale-path"\|"missing"\|"legacy"' <<<"$status_json"; then fail "hooks status is not all installed after the upgrade"; fi
no_dangling_links || fail "a dangling link was left after the upgrade"
[[ -z "$(ls "$T/.local/bin" | grep -v '^wwi$' || true)" ]] || fail "something besides the wwi link is left in ~/.local/bin"
run install.sh || fail "second upgrade run failed"   # 다시 실행해도 그대로(중복 없음)
[[ "$(count_of '# wwi-managed' "$T/.claude/settings.json")" == 7 ]] || fail "re-running the installer duplicated hook entries"

echo "9b2) order: the hooks are migrated before the old JTM.app and the old link are removed"
seed_legacy_jtm
run install.sh || fail "upgrade install failed"
migrated="$(line_of "옛 jtm 훅을 wwi 훅으로 바꿔요")"
removed_app="$(line_of "옛 JTM.app 을 지웠어요")"; removed_link="$(line_of "링크를 지웠어요")"
[[ -n "$migrated" && -n "$removed_app" && -n "$removed_link" ]] || fail "missing progress lines (migrated=$migrated app=$removed_app link=$removed_link)"
(( migrated < removed_app && removed_app < removed_link )) || fail "wrong order: migrate=$migrated old-app=$removed_app old-link=$removed_link"
no_dangling_links || fail "a dangling link after the upgrade"

echo "9c) a hand-made jtm is kept; when the hooks cannot be migrated the old jtm link is repointed (never dangling), then fixed on the next run"
reset_home; mkdir -p "$T/.local/bin"
printf '#!/bin/sh\n' > "$T/.local/bin/jtm"; chmod +x "$T/.local/bin/jtm"     # 직접 만든 jtm (링크가 아님)
run install.sh --yes || fail "install failed"
[[ -f "$T/.local/bin/jtm" && ! -L "$T/.local/bin/jtm" ]] || fail "a hand-made jtm was touched"
seed_legacy_jtm
broken_claude() { printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s","timeout":5' "$(legacy_cmd claude)" > "$T/.claude/settings.json"; }
broken_claude                                                              # 옛 훅이 들어 있지만 JSON 이 잘려서 바꾸지 못한다
run install.sh --yes || fail "install failed"                              # 훅 설치 실패는 경고일 뿐 설치를 멈추지 않는다
[[ -x "$APPS/Where Was I.app/Contents/Helpers/wwi" && ! -e "$APPS/JTM.app" ]] || fail "app was not swapped"
# 옛 훅이 부르는 경로가 계속 실행돼야 한다: 링크만 있는 게 아니라 대상이 있고 실행된다.
[[ -L "$T/.local/bin/jtm" && -x "$T/.local/bin/jtm" ]] || fail "the old jtm link is missing or not executable although old hooks still call it"
[[ "$(readlink "$T/.local/bin/jtm")" == "$APPS/Where Was I.app/Contents/Helpers/wwi" ]] || fail "the old jtm link was not repointed to the new CLI"
env HOME="$T" "$T/.local/bin/jtm" --help >/dev/null || fail "the repointed old link does not run"
no_dangling_links || fail "a dangling link although the migration failed"
grep -q "옛 jtm 훅이 아직 남아 있어서" "$LOG" || fail "no warning about the repointed old link"
grep -q "jtm-managed" "$T/.claude/settings.json" || fail "a legacy hook entry vanished although the migration failed"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s","timeout":5}]}]}}' "$(legacy_cmd claude)" > "$T/.claude/settings.json"   # 문제를 고치고 다시 실행하면 이전이 끝나고 옛 링크가 사라진다
run install.sh --yes || fail "install after fixing the settings failed"
! grep -q "jtm-managed" "$T/.claude/settings.json" "$T/.codex/hooks.json" || fail "legacy hooks remain after the fix"
[[ ! -e "$T/.local/bin/jtm" && ! -L "$T/.local/bin/jtm" ]] || fail "the repointed old link was not removed once the hooks were migrated"
no_dangling_links || fail "a dangling link after the second run"
[[ "$(count_of '# wwi-managed' "$T/.codex/hooks.json")" == 5 && "$(count_of '# wwi-managed' "$T/.claude/settings.json")" == 7 ]] || fail "hooks were not migrated on the second run"

echo "9c2) migration failure while the old app is kept in another folder is not different: link repointed, both old apps removed"
seed_legacy_jtm; broken_claude
mkdir -p "$T/Apps2/JTM.app/Contents/Helpers"; printf '#!/bin/sh\nexit 0\n' > "$T/Apps2/JTM.app/Contents/Helpers/jtm"; chmod +x "$T/Apps2/JTM.app/Contents/Helpers/jtm"
EXTRA_ENV="WWI_INSTALL_DIR=$T/Apps2" run install.sh --yes || fail "install failed"
[[ ! -e "$T/Apps2/JTM.app" && ! -e "$APPS/JTM.app" ]] || fail "an old app was left"
[[ -x "$T/.local/bin/jtm" && "$(readlink "$T/.local/bin/jtm")" == "$T/Apps2/Where Was I.app/Contents/Helpers/wwi" ]] || fail "old link not repointed into the new app"
no_dangling_links || fail "a dangling link"

echo "9f) a legacy entry written with a custom --jtm-path (/opt/x/jtm-dev) is migrated and nothing dangles"
seed_legacy_jtm
cat > "$T/.codex/hooks.json" <<JSON
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/opt/x/jtm-dev' ingest codex # jtm-managed","timeout":5}]}]}}
JSON
run install.sh || fail "install failed"
! grep -q "jtm-managed\|jtm-dev" "$T/.claude/settings.json" "$T/.codex/hooks.json" || fail "the custom-path legacy entry was not migrated"
[[ "$(count_of '# wwi-managed' "$T/.codex/hooks.json")" == 5 ]] || fail "codex: expected one managed entry per event (5)"
[[ ! -e "$T/.local/bin/jtm" && ! -L "$T/.local/bin/jtm" && ! -e "$APPS/JTM.app" ]] || fail "old link or app left"
no_dangling_links || fail "a dangling link"

echo "9g) an old JTM.app in the other Applications folder is quit and removed too (with a printed line)"
seed_legacy_jtm
mkdir -p "$T/Apps2/JTM.app/Contents"
touch "$STATE/running"
EXTRA_ENV="WWI_INSTALL_DIR=$T/Apps2 STUB_QUIT_WORKS=1" run install.sh || fail "install failed"
[[ ! -e "$T/Apps2/JTM.app" && ! -e "$APPS/JTM.app" ]] || fail "an old JTM.app was left (Apps2 or ~/Applications)"
[[ "$(grep -c "옛 JTM.app 을 지웠어요" "$LOG")" == 2 ]] || fail "expected a printed line for each removed old app"
grep -q "Removed the old $APPS/JTM.app" "$LOG" || fail "no line for the old app in the other folder"
[[ -x "$T/Apps2/Where Was I.app/Contents/Helpers/wwi" ]] || fail "the new app is not in the chosen folder"
! grep -q "직접 지워 주세요" "$LOG" || fail "still only warns about the other folder"

echo "9d) uninstall removes both the new and the legacy app, links and hooks"
seed_legacy_jtm
run install.sh --yes || fail "install failed"                              # 새 앱 + 훅(이미 옛 훅은 바뀜)
# 옛 흔적을 다시 만든다: JTM.app, jtm 링크, 옛 훅 한 줄.
mkdir -p "$APPS/JTM.app/Contents/Helpers"; printf '#!/bin/sh\nexit 0\n' > "$APPS/JTM.app/Contents/Helpers/jtm"; chmod +x "$APPS/JTM.app/Contents/Helpers/jtm"
ln -s "$APPS/JTM.app/Contents/Helpers/jtm" "$T/.local/bin/jtm"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]},{"hooks":[{"type":"command","command":"%s","timeout":5}]}]}}' "$(legacy_cmd claude)" > "$T/.claude/settings.json"
run uninstall.sh --yes || fail "uninstall failed"
[[ ! -e "$APPS/Where Was I.app" && ! -e "$APPS/JTM.app" ]] || fail "an app was left"
[[ ! -e "$T/.local/bin/wwi" && ! -L "$T/.local/bin/wwi" && ! -e "$T/.local/bin/jtm" && ! -L "$T/.local/bin/jtm" ]] || fail "a link was left"
! grep -q "jtm-managed\|wwi-managed" "$T/.claude/settings.json" "$T/.codex/hooks.json" || fail "hooks were left"
grep -q "echo mine" "$T/.claude/settings.json" || fail "the user's hook was removed"

echo "9e) uninstall on a pure JTM 0.1.x machine goes through the old jtm"
seed_legacy_jtm; rm -f "$STATE/jtm.log"
run uninstall.sh --yes || fail "legacy uninstall failed"
grep -q "hooks uninstall" "$STATE/jtm.log" || fail "the old jtm was not asked to remove its hooks"
[[ ! -e "$APPS/JTM.app" && ! -e "$T/.local/bin/jtm" && ! -L "$T/.local/bin/jtm" ]] || fail "the old app or link was left"

echo "9h) uninstall removes a JTM.app in every folder it searches, and a link repointed by a failed upgrade"
seed_legacy_jtm
mkdir -p "$T/A1/JTM.app/Contents/Helpers" "$T/A2/JTM.app/Contents/Helpers"
ln -sfn "$T/A2/JTM.app/Contents/Helpers/wwi" "$T/.local/bin/jtm"           # 훅 이전에 실패한 업그레이드가 남기는 모양(대상은 곧 지워진다)
printf '#!/bin/sh\nexit 0\n' > "$T/A2/JTM.app/Contents/Helpers/wwi"; chmod +x "$T/A2/JTM.app/Contents/Helpers/wwi"
NL=$'\n'
env -i HOME="$T" PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" STUB_STATE="$STATE" \
  WWI_INSTALL_DIR="$T/A1${NL}$T/A2" sh "$ROOT/scripts/uninstall.sh" --yes >"$LOG" 2>&1 </dev/null || fail "uninstall over two folders failed"
[[ ! -e "$T/A1/JTM.app" && ! -e "$T/A2/JTM.app" ]] || fail "an old JTM.app was left in one of the folders"
[[ ! -e "$T/.local/bin/jtm" && ! -L "$T/.local/bin/jtm" ]] || fail "the repointed old link was left"

echo "10) the real hook files were never touched"
[[ "$(hash_of "$REAL_HOME/.claude/settings.json")" == "$REAL_CLAUDE_BEFORE" ]] || fail "real ~/.claude/settings.json changed"
[[ "$(hash_of "$REAL_HOME/.codex/hooks.json")" == "$REAL_CODEX_BEFORE" ]] || fail "real ~/.codex/hooks.json changed"

echo "OK: install.sh / uninstall.sh end to end against a temp HOME (zip: $ZIP_VERSION)"
