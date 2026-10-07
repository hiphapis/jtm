#!/usr/bin/env bash
# SwiftPM 리소스 번들(jtm_JTMAppCore.bundle)에 화면 문구(en, ko)가 다 들어 있는지 확인한다. build-app.sh 가 부르고,
# test-build-app-bundle.sh 가 가짜 번들로 직접 부른다.
#   scripts/check-resource-bundle.sh <번들 경로>
# SwiftPM 은 빌드 시스템과 툴체인에 따라 번들 레이아웃이 다르다. 둘 다 받아들이고, 같은 레이아웃 안에 en 과 ko 가 다 있어야 한다.
#   중첩: <번들>/Contents/Resources/<lang>.lproj/Localizable.strings   (swiftbuild, 유니버설 빌드)
#   평평: <번들>/<lang>.lproj/Localizable.strings                      (native 빌드 시스템의 단일 아키텍처 빌드)
# 파일은 비어 있지 않고 property list(텍스트든 컴파일된 바이너리든)로 읽혀야 한다. 앱은 Bundle.module 에서 Localizable.strings 를 읽는다.
# 통과하면 레이아웃(nested 또는 flat)을 한 줄로 출력한다. 아니면 stderr 에 이유를 적고 1 로 끝난다.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <resource-bundle>" >&2; exit 2; }
BUNDLE="$1"
[[ -d "$BUNDLE" ]] || { echo "error: resource bundle not found: $BUNDLE" >&2; exit 1; }

# 한 레이아웃의 루트에 en 과 ko 문구가 다 있으면 0. 없는 언어는 MISSING 에 모은다.
MISSING=""
has_strings() {
  local root="$1" lang file
  MISSING=""
  for lang in en ko; do
    file="$root/$lang.lproj/Localizable.strings"
    if [[ -s "$file" ]] && plutil -lint "$file" >/dev/null 2>&1; then :; else MISSING="$MISSING $lang"; fi
  done
  [[ -z "$MISSING" ]]
}

if has_strings "$BUNDLE/Contents/Resources"; then echo nested; exit 0; fi
NESTED_MISSING="$MISSING"
if has_strings "$BUNDLE"; then echo flat; exit 0; fi
echo "error: $BUNDLE has no usable Localizable.strings for:${NESTED_MISSING} in Contents/Resources/<lang>.lproj, and for:${MISSING} in <lang>.lproj (the localized strings are missing)" >&2
exit 1
