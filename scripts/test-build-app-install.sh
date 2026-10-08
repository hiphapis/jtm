#!/usr/bin/env bash
# build-app.sh --install의 "실행 중인 앱 종료" 흐름을 가짜 lsappinfo/osascript로 검증한다.
# 실제 앱은 띄우지도 종료하지도 않고, ~/Applications도 건드리지 않는다(설치 위치는 임시 폴더).
#   scripts/test-build-app-install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wwi-install-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/bin"; STATE="$WORK/state"; INSTALL_DIR="$WORK/apps"; BIN_DIR="$WORK/home-bin"
mkdir -p "$STUBS" "$STATE" "$BIN_DIR"

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

# WWI_BIN_DIR: 옛 jtm 링크를 찾는 폴더도 임시 폴더로 돌린다(진짜 ~/.local/bin 은 건드리지 않는다).
export STUB_STATE="$STATE" WWI_INSTALL_DIR="$INSTALL_DIR" WWI_BIN_DIR="$BIN_DIR" WWI_BUNDLE_ID="io.github.hiphapis.jtm.installtest"
run_install() { PATH="$STUBS:$PATH" scripts/build-app.sh --install >"$WORK/out.log" 2>&1; }
fail() { echo "FAIL: $1" >&2; sed 's/^/  | /' "$WORK/out.log" | tail -15 >&2; exit 1; }

echo "1) not running: installs without asking anything to quit"
rm -f "$STATE/running" "$STATE/osascript.log"
run_install || fail "install failed"
[[ -x "$INSTALL_DIR/Where Was I.app/Contents/MacOS/WhereWasI" ]] || fail "app not installed"
[[ ! -e "$STATE/osascript.log" ]] || fail "osascript was called although the app was not running"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_DIR/Where Was I.app/Contents/Info.plist")" == "$WWI_BUNDLE_ID" ]] || fail "bundle id"

echo "2) running and quits: waits for it, then replaces"
touch "$STATE/running"; rm -f "$STATE/osascript.log"; : > "$INSTALL_DIR/Where Was I.app/OLD_MARKER"
mkdir -p "$INSTALL_DIR/JTM.app/Contents"  # 0.1.x 때의 이름으로 남아 있는 앱: 같은 번들 ID라 함께 두지 않는다
STUB_QUIT_WORKS=1 run_install || fail "install failed although the app quit"
grep -q "tell application id \"$WWI_BUNDLE_ID\" to quit" "$STATE/osascript.log" || fail "quit was not requested by bundle id"
[[ ! -e "$INSTALL_DIR/Where Was I.app/OLD_MARKER" && -x "$INSTALL_DIR/Where Was I.app/Contents/MacOS/WhereWasI" ]] || fail "app not replaced"
[[ ! -e "$INSTALL_DIR/JTM.app" ]] || fail "the old JTM.app was left next to the new app"
[[ ! -e "$INSTALL_DIR/Where Was I.app.new" && ! -e "$INSTALL_DIR/Where Was I.app.old" ]] || fail "temporary copies left behind"

echo "3) running and never quits: fails loudly after ~5 s and replaces nothing"
touch "$STATE/running"; : > "$INSTALL_DIR/Where Was I.app/KEEP_MARKER"
start=$SECONDS
if STUB_QUIT_WORKS=0 run_install; then fail "install succeeded although the app kept running"; fi
elapsed=$((SECONDS - start))
grep -q "still running" "$WORK/out.log" || fail "no loud error message"
[[ -e "$INSTALL_DIR/Where Was I.app/KEEP_MARKER" ]] || fail "the installed app was replaced anyway"
(( elapsed >= 5 )) || fail "gave up after only ${elapsed}s"

echo "4) an old jtm link into JTM.app is repointed to the new CLI before JTM.app is removed (never left dangling)"
rm -f "$STATE/running"
mkdir -p "$INSTALL_DIR/JTM.app/Contents/Helpers"
printf '#!/bin/sh\nexit 0\n' > "$INSTALL_DIR/JTM.app/Contents/Helpers/jtm"; chmod +x "$INSTALL_DIR/JTM.app/Contents/Helpers/jtm"
ln -sfn "$INSTALL_DIR/JTM.app/Contents/Helpers/jtm" "$BIN_DIR/jtm"
run_install || fail "install failed"
[[ ! -e "$INSTALL_DIR/JTM.app" ]] || fail "the old JTM.app was left"
[[ -L "$BIN_DIR/jtm" && -x "$BIN_DIR/jtm" ]] || fail "the old jtm link is missing or does not resolve to an executable"
[[ "$(readlink "$BIN_DIR/jtm")" == "$INSTALL_DIR/Where Was I.app/Contents/Helpers/wwi" ]] || fail "the old jtm link was not repointed to the new CLI"
"$BIN_DIR/jtm" --help >/dev/null || fail "the repointed old link does not run"
grep -q "hooks install" "$WORK/out.log" || fail "no instruction to migrate the hooks"

echo "5) a hand-made jtm file and a foreign jtm link are left alone; JTM.app is still removed"
for kind in file link; do
  rm -f "$BIN_DIR/jtm"; mkdir -p "$INSTALL_DIR/JTM.app/Contents"
  if [[ "$kind" == file ]]; then printf '#!/bin/sh\n' > "$BIN_DIR/jtm"; else ln -s /usr/local/bin/my-own-tool "$BIN_DIR/jtm"; fi
  run_install || fail "install failed ($kind)"
  [[ ! -e "$INSTALL_DIR/JTM.app" ]] || fail "JTM.app left ($kind)"
  if [[ "$kind" == file ]]; then [[ -f "$BIN_DIR/jtm" && ! -L "$BIN_DIR/jtm" ]] || fail "hand-made jtm touched"
  else [[ "$(readlink "$BIN_DIR/jtm")" == /usr/local/bin/my-own-tool ]] || fail "foreign link touched"; fi
done

echo "OK: install flow (not running / quits / never quits / old link repointed)"
