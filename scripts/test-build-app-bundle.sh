#!/usr/bin/env bash
# build-app.sh 가 만드는 번들과 배포 묶음(zip, dmg)을 검사한다: 아이콘 키와 .icns, 화면 문구(영어/한국어) 리소스, 서명, dmg 내용, 체크섬, 번들 ID 덮어쓰기.
# 앱은 띄우지도 번들 안의 실행 파일을 실행하지도 않는다. 결과물은 임시 폴더(WWI_DIST_DIR)에만 쓴다.
#   scripts/test-build-app-bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wwi-bundle-test.XXXXXX")"
MOUNT=""
cleanup() {
  [[ -z "$MOUNT" ]] || hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
LOG="$WORK/out.log"
fail() { echo "FAIL: $1" >&2; sed 's/^/  | /' "$LOG" | tail -15 >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$ROOT/.build/Where Was I.app/Contents/Info.plist"; }

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
ICON="$ROOT/Resources/AppIcon/AppIcon.icns"
# 이 Mac 의 아키텍처 하나만 빌드한다(유니버설 빌드는 릴리스 워크플로가 이미 한다).
export WWI_ARCHS="$(uname -m)" WWI_DIST_DIR="$WORK/dist"

echo "0) resource bundle check accepts the flat and the nested SwiftPM layout, rejects a bundle without ko"
CHECK=scripts/check-resource-bundle.sh
fake_bundle() { # <경로> <레이아웃: flat|nested> <언어...>
  local dir="$1" layout="$2" lang root; shift 2
  root="$dir"; [[ "$layout" == nested ]] && root="$dir/Contents/Resources"
  mkdir -p "$root"
  for lang in "$@"; do
    mkdir -p "$root/$lang.lproj"
    printf '"sectionWaiting" = "x";\n' > "$root/$lang.lproj/Localizable.strings"
  done
}
fake_bundle "$WORK/fake/flat.bundle" flat en ko
fake_bundle "$WORK/fake/nested.bundle" nested en ko
[[ "$("$CHECK" "$WORK/fake/flat.bundle" 2>"$LOG")" == flat ]] || fail "a flat bundle was not accepted"
[[ "$("$CHECK" "$WORK/fake/nested.bundle" 2>"$LOG")" == nested ]] || fail "a nested bundle was not accepted"
# 컴파일된(바이너리 property list) 문구도 받아들인다.
fake_bundle "$WORK/fake/binary.bundle" flat en ko
plutil -convert binary1 "$WORK/fake/binary.bundle/en.lproj/Localizable.strings" "$WORK/fake/binary.bundle/ko.lproj/Localizable.strings"
"$CHECK" "$WORK/fake/binary.bundle" >"$LOG" 2>&1 || fail "a bundle with compiled (binary) strings was not accepted"
for layout in flat nested; do
  fake_bundle "$WORK/fake/no-ko-$layout.bundle" "$layout" en
  if "$CHECK" "$WORK/fake/no-ko-$layout.bundle" >"$LOG" 2>&1; then fail "a $layout bundle without ko was accepted"; fi
  grep -q "the localized strings are missing" "$LOG" || fail "no loud error for a $layout bundle without ko"
done
# 한 레이아웃 안에 en 과 ko 가 다 있어야 한다: 평평에 en, 중첩에 ko 로 갈라진 번들은 거절한다.
fake_bundle "$WORK/fake/split.bundle" flat en
fake_bundle "$WORK/fake/split.bundle" nested ko
if "$CHECK" "$WORK/fake/split.bundle" >"$LOG" 2>&1; then fail "a bundle with en and ko in different layouts was accepted"; fi
# 비어 있거나 읽을 수 없는 문구 파일, 번들이 없는 경우도 거절한다.
fake_bundle "$WORK/fake/empty.bundle" flat en ko
: > "$WORK/fake/empty.bundle/ko.lproj/Localizable.strings"
if "$CHECK" "$WORK/fake/empty.bundle" >"$LOG" 2>&1; then fail "a bundle with an empty ko strings file was accepted"; fi
fake_bundle "$WORK/fake/garbage.bundle" nested en ko
echo "not a property list {" > "$WORK/fake/garbage.bundle/Contents/Resources/en.lproj/Localizable.strings"
if "$CHECK" "$WORK/fake/garbage.bundle" >"$LOG" 2>&1; then fail "a bundle with an unreadable en strings file was accepted"; fi
if "$CHECK" "$WORK/fake/missing.bundle" >"$LOG" 2>&1; then fail "a missing bundle was accepted"; fi

echo "1) a missing or invalid icon fails loudly, before any build"
if WWI_ICON="$WORK/nope.icns" scripts/build-app.sh >"$LOG" 2>&1; then fail "build succeeded without an icon"; fi
grep -q "app icon not found" "$LOG" || fail "no loud error for the missing icon"
echo "not an icns" > "$WORK/fake.icns"
if WWI_ICON="$WORK/fake.icns" scripts/build-app.sh >"$LOG" 2>&1; then fail "build succeeded with a file that is not an icns"; fi
grep -q "not an .icns file" "$LOG" || fail "no loud error for the invalid icon"

echo "2) --dmg needs --release"
if scripts/build-app.sh --dmg >"$LOG" 2>&1; then fail "--dmg without --release was accepted"; fi
grep -q "together with --release" "$LOG" || fail "no explanation for --dmg without --release"

echo "3) release build with a bundle id override: icon keys, icns, localized strings, signature"
export WWI_BUNDLE_ID="com.example.wwi.bundletest"
scripts/build-app.sh --release --dmg >"$LOG" 2>&1 || fail "release build failed"
APP="$ROOT/.build/Where Was I.app"
[[ "$(plist CFBundleIdentifier)" == "$WWI_BUNDLE_ID" ]] || fail "bundle id override not applied"
[[ "$(plist CFBundleIconFile)" == "AppIcon" ]] || fail "CFBundleIconFile"
[[ "$(plist CFBundleIconName)" == "AppIcon" ]] || fail "CFBundleIconName"
[[ "$(plist CFBundleShortVersionString)" == "$VERSION" ]] || fail "version in Info.plist"
cmp -s "$APP/Contents/Resources/AppIcon.icns" "$ICON" || fail "AppIcon.icns in the bundle differs from Resources/AppIcon/AppIcon.icns"
RES_REL="Contents/Resources/where-was-i_WWIAppCore.bundle"
# SwiftPM 이 만든 레이아웃 그대로 들어 있어야 한다(평평하면 번들 바로 아래, 아니면 Contents/Resources 아래).
[[ -d "$APP/$RES_REL/en.lproj" ]] || RES_REL="$RES_REL/Contents/Resources"
for lang in en ko; do
  [[ -s "$APP/$RES_REL/$lang.lproj/Localizable.strings" ]] || fail "the app lacks $lang.lproj/Localizable.strings (localized strings)"
done
[[ "$(plutil -extract sectionWaiting raw "$APP/$RES_REL/en.lproj/Localizable.strings")" == "Waiting for me" ]] || fail "English string table content"
[[ "$(plutil -extract sectionActive raw "$APP/$RES_REL/ko.lproj/Localizable.strings")" == "진행 중" ]] || fail "Korean string table content"
[[ "$(plist CFBundleDevelopmentRegion)" == "en" ]] || fail "CFBundleDevelopmentRegion"
[[ "$(plist CFBundleLocalizations:0)" == "en" && "$(plist CFBundleLocalizations:1)" == "ko" ]] || fail "CFBundleLocalizations must list en and ko"
codesign --verify --deep --strict "$APP" || fail "app signature"
codesign --verify --strict "$APP/Contents/Helpers/wwi" || fail "helper signature"

echo "4) zip is unchanged in shape and carries the icon"
ZIP="$WWI_DIST_DIR/WhereWasI-$VERSION.zip"
[[ -f "$ZIP" && -f "$ZIP.sha256" ]] || fail "zip or its sha256 missing"
LISTING="$(unzip -Z1 "$ZIP")"
grep -qx 'Where Was I.app/Contents/Helpers/wwi' <<<"$LISTING" || fail "zip lacks the helper"
grep -qx 'Where Was I.app/Contents/Resources/AppIcon.icns' <<<"$LISTING" || fail "zip lacks the icon"
for lang in en ko; do
  grep -qx "Where Was I.app/$RES_REL/$lang.lproj/Localizable.strings" <<<"$LISTING" || fail "zip lacks the $lang strings"
done
(cd "$WWI_DIST_DIR" && shasum -a 256 -c "WhereWasI-$VERSION.zip.sha256" >/dev/null) || fail "zip sha256 does not verify"

echo "5) dmg: UDZO, volume Where Was I, Where Was I.app + Applications link, sha256"
DMG="$WWI_DIST_DIR/WhereWasI-$VERSION.dmg"
[[ -f "$DMG" && -f "$DMG.sha256" ]] || fail "dmg or its sha256 missing"
(cd "$WWI_DIST_DIR" && shasum -a 256 -c "WhereWasI-$VERSION.dmg.sha256" >/dev/null) || fail "dmg sha256 does not verify"
[[ "$(cut -d' ' -f3 "$DMG.sha256")" == "WhereWasI-$VERSION.dmg" ]] || fail "dmg sha256 must name the file without a path"
hdiutil imageinfo "$DMG" | grep -q '^Format: UDZO' || fail "dmg is not UDZO"
MOUNT="$WORK/mount"; mkdir -p "$MOUNT"
hdiutil attach "$DMG" -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" || fail "dmg does not mount"
[[ "$(diskutil info "$MOUNT" | sed -n 's/^ *Volume Name: *//p')" == "Where Was I" ]] || fail "volume name is not Where Was I"
[[ -d "$MOUNT/Where Was I.app" ]] || fail "dmg lacks Where Was I.app"
[[ -L "$MOUNT/Applications" && "$(readlink "$MOUNT/Applications")" == "/Applications" ]] || fail "dmg lacks the /Applications link"
[[ -x "$MOUNT/Where Was I.app/Contents/Helpers/wwi" ]] || fail "dmg app lacks the helper"
cmp -s "$MOUNT/Where Was I.app/Contents/Resources/AppIcon.icns" "$ICON" || fail "dmg app icon differs"
for lang in en ko; do
  [[ -s "$MOUNT/Where Was I.app/$RES_REL/$lang.lproj/Localizable.strings" ]] || fail "dmg app lacks the $lang strings"
done
codesign --verify --deep --strict "$MOUNT/Where Was I.app" || fail "app inside the dmg does not verify"
hdiutil detach "$MOUNT" -quiet; MOUNT=""

echo "OK: bundle icon, localized strings, signature, zip, dmg (bundle id override $WWI_BUNDLE_ID)"
