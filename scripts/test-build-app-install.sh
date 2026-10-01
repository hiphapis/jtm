#!/usr/bin/env bash
# build-app.sh --install의 "실행 중인 앱 종료" 흐름을 가짜 lsappinfo/osascript로 검증한다.
# 실제 앱은 띄우지도 종료하지도 않고, ~/Applications도 건드리지 않는다(설치 위치는 임시 폴더).
#   scripts/test-build-app-install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jtm-install-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/bin"; STATE="$WORK/state"; INSTALL_DIR="$WORK/apps"
mkdir -p "$STUBS" "$STATE"

# lsappinfo: "실행 중" 표식 파일이 있으면 ASN을 낸다.
cat > "$STUBS/lsappinfo" <<'STUB'
#!/usr/bin/env bash
[[ -e "$STUB_STATE/running" ]] && echo 'ASN:0x0-0x1:'
exit 0
STUB
# osascript: 호출을 기록하고, STUB_QUIT_WORKS=1이면 0.3초 뒤 "종료"한다.
cat > "$STUBS/osascript" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_STATE/osascript.log"
if [[ "${STUB_QUIT_WORKS:-0}" == 1 ]]; then sleep 0.3; rm -f "$STUB_STATE/running"; fi
exit 0
STUB
chmod +x "$STUBS/lsappinfo" "$STUBS/osascript"

export STUB_STATE="$STATE" JTM_INSTALL_DIR="$INSTALL_DIR" JTM_BUNDLE_ID="io.github.hiphapis.jtm.installtest"
run_install() { PATH="$STUBS:$PATH" scripts/build-app.sh --install >"$WORK/out.log" 2>&1; }
fail() { echo "FAIL: $1" >&2; sed 's/^/  | /' "$WORK/out.log" | tail -15 >&2; exit 1; }

echo "1) not running: installs without asking anything to quit"
rm -f "$STATE/running" "$STATE/osascript.log"
run_install || fail "install failed"
[[ -x "$INSTALL_DIR/JTM.app/Contents/MacOS/JTMApp" ]] || fail "app not installed"
[[ ! -e "$STATE/osascript.log" ]] || fail "osascript was called although the app was not running"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_DIR/JTM.app/Contents/Info.plist")" == "$JTM_BUNDLE_ID" ]] || fail "bundle id"

echo "2) running and quits: waits for it, then replaces"
touch "$STATE/running"; rm -f "$STATE/osascript.log"; : > "$INSTALL_DIR/JTM.app/OLD_MARKER"
STUB_QUIT_WORKS=1 run_install || fail "install failed although the app quit"
grep -q "tell application id \"$JTM_BUNDLE_ID\" to quit" "$STATE/osascript.log" || fail "quit was not requested by bundle id"
[[ ! -e "$INSTALL_DIR/JTM.app/OLD_MARKER" && -x "$INSTALL_DIR/JTM.app/Contents/MacOS/JTMApp" ]] || fail "app not replaced"
[[ ! -e "$INSTALL_DIR/JTM.app.new" && ! -e "$INSTALL_DIR/JTM.app.old" ]] || fail "temporary copies left behind"

echo "3) running and never quits: fails loudly after ~5 s and replaces nothing"
touch "$STATE/running"; : > "$INSTALL_DIR/JTM.app/KEEP_MARKER"
start=$SECONDS
if STUB_QUIT_WORKS=0 run_install; then fail "install succeeded although the app kept running"; fi
elapsed=$((SECONDS - start))
grep -q "still running" "$WORK/out.log" || fail "no loud error message"
[[ -e "$INSTALL_DIR/JTM.app/KEEP_MARKER" ]] || fail "the installed app was replaced anyway"
(( elapsed >= 5 )) || fail "gave up after only ${elapsed}s"

echo "OK: install flow (not running / quits / never quits)"
