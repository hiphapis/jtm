#!/usr/bin/env bash
# JTM.app을 조립한다: release 빌드 → 번들(앱 + 내장 CLI) → ad-hoc 서명. 결과는 .build/JTM.app.
#   scripts/build-app.sh                         빌드와 서명까지
#   scripts/build-app.sh --install               그 뒤 ~/Applications/JTM.app 으로 복사(실행 중이면 먼저 종료)
#   scripts/build-app.sh --release [--version X.Y.Z] [--dmg]
#                                                배포 묶음: x86_64+arm64 유니버설로 빌드하고 dist/JTM-<version>.zip 과 .sha256 을 만든다
#                                                --dmg 를 더하면 dist/JTM-<version>.dmg(JTM.app + Applications 링크)와 .sha256 도 만든다
# 버전은 저장소 루트의 VERSION 파일이 기준이고 --version 이 있으면 그것이 우선한다(CFBundleShortVersionString).
# 빌드 번호(CFBundleVersion)는 JTM_BUILD_NUMBER, 없으면 git 커밋 수, 그것도 없으면 1.
# 앱은 항상 `open`으로만 띄운다. 번들 안의 실행 파일을 터미널에서 직접 실행하지 않는다.
# 환경 변수(개발/테스트용): JTM_BUNDLE_ID(기본 io.github.hiphapis.jtm), JTM_INSTALL_DIR(기본 ~/Applications),
#   JTM_ARCHS(공백으로 구분한 빌드 아키텍처. 기본: 개발 빌드는 이 Mac 것만, --release는 "arm64 x86_64"),
#   JTM_DIST_DIR(--release 결과를 쓰는 곳. 기본 dist), JTM_ICON(앱 아이콘 .icns. 기본 Resources/AppIcon/AppIcon.icns)
set -euo pipefail

INSTALL=0
RELEASE=0
DMG=0
VERSION_ARG=""
while (( $# > 0 )); do
  case "$1" in
    --install) INSTALL=1 ;;
    --release) RELEASE=1 ;;
    --dmg) DMG=1 ;;
    --version)
      [[ $# -ge 2 ]] || { echo "error: --version needs a value" >&2; exit 2; }
      VERSION_ARG="$2"; shift ;;
    --version=*) VERSION_ARG="${1#--version=}" ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ "$DMG" == 1 && "$RELEASE" == 0 ]]; then
  echo "error: --dmg is part of the release package; use it together with --release" >&2
  exit 2
fi

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/.build/JTM.app"
# 번들 ID는 앱을 식별한다(로그 subsystem, 로그인 항목, 메뉴바 항목 상태). 번들 안의 실행 파일을 직접 실행하면
# macOS가 그 번들 ID의 메뉴바 가시성 상태를 오염시킬 수 있어서, 앱은 항상 `open`으로만 띄운다.
# AppIdentity.bundleIdentifier 와 같아야 한다(Tests/JTMAppCoreTests/AppIdentityTests 가 확인한다).
BUNDLE_ID="${JTM_BUNDLE_ID:-io.github.hiphapis.jtm}"
INSTALL_DIR="${JTM_INSTALL_DIR:-$HOME/Applications}"
DIST="${JTM_DIST_DIR:-$ROOT/dist}"
# 앱 아이콘. 없거나 .icns 가 아니면 오래 걸리는 빌드 전에 바로 실패한다(아이콘 없는 앱이 조용히 나가지 않게).
ICON="${JTM_ICON:-$ROOT/Resources/AppIcon/AppIcon.icns}"
[[ -f "$ICON" ]] || { echo "error: app icon not found: $ICON" >&2; exit 1; }
[[ "$(head -c 4 "$ICON")" == "icns" ]] || { echo "error: $ICON is not an .icns file" >&2; exit 1; }

# 버전: --version > VERSION 파일.
VERSION="$VERSION_ARG"
if [[ -z "$VERSION" ]]; then
  [[ -f "$ROOT/VERSION" ]] || { echo "error: no VERSION file at the repository root and no --version given" >&2; exit 1; }
  VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "error: version '$VERSION' is not X.Y.Z (optionally -suffix)" >&2
  exit 1
fi
BUILD_NUMBER="${JTM_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# 빌드 아키텍처. 배포 묶음은 x86_64 Mac에서도 열려야 해서 유니버설로 만든다.
ARCHS="${JTM_ARCHS:-}"
if [[ -z "$ARCHS" && "$RELEASE" == 1 ]]; then ARCHS="arm64 x86_64"; fi
ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done

# 제품마다 따로 빌드한다(여러 --arch 와 함께 --product 를 여러 번 주면 마지막 것만 빌드된다).
for product in JTMApp jtm; do
  echo "==> swift build -c release --product $product ${ARCHS:+(archs: $ARCHS)}"
  swift build -c release --product "$product" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
done
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "==> assembling $APP (version $VERSION, build $BUILD_NUMBER, $BUNDLE_ID)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/JTMApp" "$APP/Contents/MacOS/JTMApp"
# 내장 CLI. 설치 때 ~/.local/bin/jtm 이 이 파일을 가리키는 심볼릭 링크가 된다.
cp "$BIN_DIR/jtm" "$APP/Contents/Helpers/jtm"
chmod 755 "$APP/Contents/MacOS/JTMApp" "$APP/Contents/Helpers/jtm"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# 화면 문구(영어 기본, 한국어)가 든 SwiftPM 리소스 번들. 앱 코드의 Bundle.module 이 Contents/Resources 에서 이 번들을 찾는다.
# 없으면 문구가 키 이름으로 보이므로, 조립 전에 두 언어가 다 들어 있는지 확인하고 아니면 실패한다.
# 번들 안쪽 레이아웃(중첩 또는 평평)은 SwiftPM 이 만든 그대로 복사한다. Bundle 이 둘 다 읽는다.
RES_NAME="jtm_JTMAppCore.bundle"
RES_BUNDLE="$BIN_DIR/$RES_NAME"
RES_LAYOUT="$("$ROOT/scripts/check-resource-bundle.sh" "$RES_BUNDLE")"
echo "==> resource bundle layout: $RES_LAYOUT"
ditto "$RES_BUNDLE" "$APP/Contents/Resources/$RES_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
  <key>CFBundleExecutable</key><string>JTMApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>JTM</string>
  <key>CFBundleDisplayName</key><string>JTM</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

# 안쪽(내장 CLI, 문구 리소스 번들)을 먼저, 그 다음 앱 전체를 서명한다(바깥을 먼저 하면 안쪽 서명이 봉인을 깬다).
echo "==> codesign (ad-hoc): helper and resource bundle first, then the app"
codesign -s - --force -i "$BUNDLE_ID.cli" "$APP/Contents/Helpers/jtm"
codesign -s - --force "$APP/Contents/Resources/$RES_NAME"
codesign -s - --force "$APP"
codesign --verify --deep --strict "$APP"

echo "built $APP"

if [[ "$RELEASE" == 1 ]]; then
  ZIP="$DIST/JTM-$VERSION.zip"
  mkdir -p "$DIST"
  rm -f "$ZIP" "$ZIP.sha256"
  echo "==> packaging $ZIP"
  # 확장 속성(출처 표시 등)은 담지 않는다: 압축을 풀 때 `._*` 찌꺼기가 생기지 않게.
  ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$APP" "$ZIP"
  # 파일 이름만 적어서(경로 없이) `shasum -a 256 -c JTM-<version>.zip.sha256`이 그대로 동작한다.
  (cd "$DIST" && shasum -a 256 "JTM-$VERSION.zip" > "JTM-$VERSION.zip.sha256")
  LISTING="$(unzip -Z1 "$ZIP")"  # 파이프로 grep -q 에 바로 넘기면 pipefail 아래서 SIGPIPE 로 실패한다
  grep -qx 'JTM.app/Contents/Helpers/jtm' <<<"$LISTING" \
    || { echo "error: the zip does not contain JTM.app/Contents/Helpers/jtm" >&2; exit 1; }
  echo "wrote $ZIP"
  echo "wrote $ZIP.sha256 ($(cut -d' ' -f1 "$ZIP.sha256"))"
fi

# 디스크 이미지: JTM.app + /Applications 링크. 볼륨 아이콘은 SetFile(Xcode 명령줄 도구)이 있을 때만 붙인다.
if [[ "$DMG" == 1 ]]; then
  DMG_FILE="$DIST/JTM-$VERSION.dmg"
  rm -f "$DMG_FILE" "$DMG_FILE.sha256"
  DMG_WORK="$(mktemp -d "${TMPDIR:-/tmp}/jtm-dmg.XXXXXX")"
  DMG_MOUNT=""
  cleanup_dmg() {
    [[ -z "$DMG_MOUNT" ]] || hdiutil detach "$DMG_MOUNT" -quiet -force >/dev/null 2>&1 || true
    rm -rf "$DMG_WORK"
  }
  trap cleanup_dmg EXIT
  echo "==> packaging $DMG_FILE"
  STAGE="$DMG_WORK/stage"
  mkdir -p "$STAGE"
  ditto --norsrc --noextattr --noqtn --noacl "$APP" "$STAGE/JTM.app"
  ln -s /Applications "$STAGE/Applications"
  cp "$ICON" "$STAGE/.VolumeIcon.icns"
  hdiutil create -quiet -srcfolder "$STAGE" -volname JTM -fs HFS+ -format UDRW -ov "$DMG_WORK/rw.dmg"
  if command -v SetFile >/dev/null 2>&1; then
    DMG_MOUNT="$DMG_WORK/mount"
    mkdir -p "$DMG_MOUNT"
    hdiutil attach "$DMG_WORK/rw.dmg" -quiet -nobrowse -noautoopen -mountpoint "$DMG_MOUNT"
    SetFile -a C "$DMG_MOUNT"  # 볼륨 루트의 .VolumeIcon.icns 를 아이콘으로 쓴다
    hdiutil detach "$DMG_MOUNT" -quiet
    DMG_MOUNT=""
  else
    echo "note: SetFile not found; the disk image gets no custom volume icon" >&2
  fi
  hdiutil convert "$DMG_WORK/rw.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "$DMG_FILE"
  hdiutil verify -quiet "$DMG_FILE"
  (cd "$DIST" && shasum -a 256 "JTM-$VERSION.dmg" > "JTM-$VERSION.dmg.sha256")
  # 열어서 내용을 확인한다: 앱(내장 CLI 포함)과 Applications 링크가 있어야 한다.
  DMG_MOUNT="$DMG_WORK/check"
  mkdir -p "$DMG_MOUNT"
  hdiutil attach "$DMG_FILE" -quiet -readonly -nobrowse -noautoopen -mountpoint "$DMG_MOUNT"
  [[ -x "$DMG_MOUNT/JTM.app/Contents/Helpers/jtm" && -f "$DMG_MOUNT/JTM.app/Contents/Resources/AppIcon.icns" && -L "$DMG_MOUNT/Applications" ]] \
    || { echo "error: the dmg does not contain JTM.app (with the CLI and the icon) and an Applications link" >&2; exit 1; }
  hdiutil detach "$DMG_MOUNT" -quiet
  DMG_MOUNT=""
  echo "wrote $DMG_FILE"
  echo "wrote $DMG_FILE.sha256 ($(cut -d' ' -f1 "$DMG_FILE.sha256"))"
fi

# 이 번들 ID의 앱이 떠 있는가(Launch Services 기준. 자동화 권한이 필요 없다).
app_running() {
  [[ -n "$(lsappinfo find "bundleid=$BUNDLE_ID" 2>/dev/null)" ]]
}

# 떠 있으면 정상 종료를 요청하고 최대 5초 기다린다. 그래도 떠 있으면 실패한다(강제로 죽이지 않는다).
quit_running_app() {
  app_running || return 0
  echo "==> quitting the running JTM ($BUNDLE_ID)"
  # 처음에는 자동화 권한 대화상자가 뜰 수 있어서 osascript는 백그라운드로 두고 우리가 시간을 잰다.
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 &
  local quit_pid=$!
  local waited=0
  while app_running && (( waited < 50 )); do sleep 0.1; waited=$((waited + 1)); done
  kill "$quit_pid" 2>/dev/null || true
  wait "$quit_pid" 2>/dev/null || true
  if app_running; then
    echo "error: JTM ($BUNDLE_ID) is still running 5 s after the quit request; quit it and run --install again (nothing was replaced)" >&2
    exit 1
  fi
}

if [[ "$INSTALL" == 1 ]]; then
  DEST="$INSTALL_DIR/JTM.app"
  NEW="$DEST.new"
  OLD="$DEST.old"
  mkdir -p "$INSTALL_DIR"
  quit_running_app
  # 임시 위치에 먼저 복사해서, 복사가 실패해도 설치본이 사라지지 않게 한다.
  rm -rf "$NEW" "$OLD"
  ditto "$APP" "$NEW"
  codesign --verify --deep --strict "$NEW"
  if [[ -e "$DEST" ]]; then mv "$DEST" "$OLD"; fi
  mv "$NEW" "$DEST"
  rm -rf "$OLD"
  echo "installed $DEST"
  echo "run it with: open \"$DEST\"   (never exec the binary inside the bundle)"
fi
