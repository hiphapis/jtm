#!/usr/bin/env bash
# build-app.sh 가 만드는 번들과 배포 묶음(zip, dmg)을 검사한다: 아이콘 키와 .icns, 화면 문구(영어/한국어) 리소스, 서명, dmg 내용, 체크섬, 번들 ID 덮어쓰기.
# 앱은 띄우지도 번들 안의 실행 파일을 실행하지도 않는다. 결과물은 임시 폴더(JTM_DIST_DIR)에만 쓴다.
#   scripts/test-build-app-bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jtm-bundle-test.XXXXXX")"
MOUNT=""
cleanup() {
  [[ -z "$MOUNT" ]] || hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
LOG="$WORK/out.log"
fail() { echo "FAIL: $1" >&2; sed 's/^/  | /' "$LOG" | tail -15 >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$ROOT/.build/JTM.app/Contents/Info.plist"; }

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
ICON="$ROOT/Resources/AppIcon/AppIcon.icns"
# 이 Mac 의 아키텍처 하나만 빌드한다(유니버설 빌드는 릴리스 워크플로가 이미 한다).
export JTM_ARCHS="$(uname -m)" JTM_DIST_DIR="$WORK/dist"

echo "1) a missing or invalid icon fails loudly, before any build"
if JTM_ICON="$WORK/nope.icns" scripts/build-app.sh >"$LOG" 2>&1; then fail "build succeeded without an icon"; fi
grep -q "app icon not found" "$LOG" || fail "no loud error for the missing icon"
echo "not an icns" > "$WORK/fake.icns"
if JTM_ICON="$WORK/fake.icns" scripts/build-app.sh >"$LOG" 2>&1; then fail "build succeeded with a file that is not an icns"; fi
grep -q "not an .icns file" "$LOG" || fail "no loud error for the invalid icon"

echo "2) --dmg needs --release"
if scripts/build-app.sh --dmg >"$LOG" 2>&1; then fail "--dmg without --release was accepted"; fi
grep -q "together with --release" "$LOG" || fail "no explanation for --dmg without --release"

echo "3) release build with a bundle id override: icon keys, icns, localized strings, signature"
export JTM_BUNDLE_ID="com.example.jtm.bundletest"
scripts/build-app.sh --release --dmg >"$LOG" 2>&1 || fail "release build failed"
APP="$ROOT/.build/JTM.app"
[[ "$(plist CFBundleIdentifier)" == "$JTM_BUNDLE_ID" ]] || fail "bundle id override not applied"
[[ "$(plist CFBundleIconFile)" == "AppIcon" ]] || fail "CFBundleIconFile"
[[ "$(plist CFBundleIconName)" == "AppIcon" ]] || fail "CFBundleIconName"
[[ "$(plist CFBundleShortVersionString)" == "$VERSION" ]] || fail "version in Info.plist"
cmp -s "$APP/Contents/Resources/AppIcon.icns" "$ICON" || fail "AppIcon.icns in the bundle differs from Resources/AppIcon/AppIcon.icns"
RES_REL="Contents/Resources/jtm_JTMAppCore.bundle/Contents/Resources"
for lang in en ko; do
  [[ -s "$APP/$RES_REL/$lang.lproj/Localizable.strings" ]] || fail "the app lacks $lang.lproj/Localizable.strings (localized strings)"
done
[[ "$(plutil -extract sectionWaiting raw "$APP/$RES_REL/en.lproj/Localizable.strings")" == "Waiting for me" ]] || fail "English string table content"
[[ "$(plutil -extract sectionActive raw "$APP/$RES_REL/ko.lproj/Localizable.strings")" == "진행 중" ]] || fail "Korean string table content"
[[ "$(plist CFBundleDevelopmentRegion)" == "en" ]] || fail "CFBundleDevelopmentRegion"
[[ "$(plist CFBundleLocalizations:0)" == "en" && "$(plist CFBundleLocalizations:1)" == "ko" ]] || fail "CFBundleLocalizations must list en and ko"
codesign --verify --deep --strict "$APP" || fail "app signature"
codesign --verify --strict "$APP/Contents/Helpers/jtm" || fail "helper signature"

echo "4) zip is unchanged in shape and carries the icon"
ZIP="$JTM_DIST_DIR/JTM-$VERSION.zip"
[[ -f "$ZIP" && -f "$ZIP.sha256" ]] || fail "zip or its sha256 missing"
LISTING="$(unzip -Z1 "$ZIP")"
grep -qx 'JTM.app/Contents/Helpers/jtm' <<<"$LISTING" || fail "zip lacks the helper"
grep -qx 'JTM.app/Contents/Resources/AppIcon.icns' <<<"$LISTING" || fail "zip lacks the icon"
for lang in en ko; do
  grep -qx "JTM.app/$RES_REL/$lang.lproj/Localizable.strings" <<<"$LISTING" || fail "zip lacks the $lang strings"
done
(cd "$JTM_DIST_DIR" && shasum -a 256 -c "JTM-$VERSION.zip.sha256" >/dev/null) || fail "zip sha256 does not verify"

echo "5) dmg: UDZO, volume JTM, JTM.app + Applications link, sha256"
DMG="$JTM_DIST_DIR/JTM-$VERSION.dmg"
[[ -f "$DMG" && -f "$DMG.sha256" ]] || fail "dmg or its sha256 missing"
(cd "$JTM_DIST_DIR" && shasum -a 256 -c "JTM-$VERSION.dmg.sha256" >/dev/null) || fail "dmg sha256 does not verify"
[[ "$(cut -d' ' -f3 "$DMG.sha256")" == "JTM-$VERSION.dmg" ]] || fail "dmg sha256 must name the file without a path"
hdiutil imageinfo "$DMG" | grep -q '^Format: UDZO' || fail "dmg is not UDZO"
MOUNT="$WORK/mount"; mkdir -p "$MOUNT"
hdiutil attach "$DMG" -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" || fail "dmg does not mount"
[[ "$(diskutil info "$MOUNT" | sed -n 's/^ *Volume Name: *//p')" == "JTM" ]] || fail "volume name is not JTM"
[[ -d "$MOUNT/JTM.app" ]] || fail "dmg lacks JTM.app"
[[ -L "$MOUNT/Applications" && "$(readlink "$MOUNT/Applications")" == "/Applications" ]] || fail "dmg lacks the /Applications link"
[[ -x "$MOUNT/JTM.app/Contents/Helpers/jtm" ]] || fail "dmg app lacks the helper"
cmp -s "$MOUNT/JTM.app/Contents/Resources/AppIcon.icns" "$ICON" || fail "dmg app icon differs"
for lang in en ko; do
  [[ -s "$MOUNT/JTM.app/$RES_REL/$lang.lproj/Localizable.strings" ]] || fail "dmg app lacks the $lang strings"
done
codesign --verify --deep --strict "$MOUNT/JTM.app" || fail "app inside the dmg does not verify"
hdiutil detach "$MOUNT" -quiet; MOUNT=""

echo "OK: bundle icon, localized strings, signature, zip, dmg (bundle id override $JTM_BUNDLE_ID)"
