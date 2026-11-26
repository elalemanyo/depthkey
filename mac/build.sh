#!/bin/bash
# Builds DepthKey.app (Release) into build/, and with `dmg` also build/DepthKey.dmg.
#   ./build.sh            # build/DepthKey.app
#   ./build.sh dmg        # + build/DepthKey.dmg
#   ./build.sh run        # build and open
# SIGN_IDENTITY="Apple Development" ./build.sh   signs with your certificate instead of ad hoc,
# so macOS keeps the camera permission across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

command -v xcodegen >/dev/null || { echo "Needs XcodeGen: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet

xcodebuild -project DepthKey.xcodeproj -scheme DepthKey -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData -quiet build

rm -rf build/DepthKey.app
cp -R build/DerivedData/Build/Products/Release/DepthKey.app build/
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --entitlements DepthKey/DepthKey.entitlements \
    --sign "$SIGN_IDENTITY" build/DepthKey.app
fi
echo "Built build/DepthKey.app"

case "${1:-}" in
  dmg)
    staging=$(mktemp -d)
    cp -R build/DepthKey.app "$staging/"
    ln -s /Applications "$staging/Applications"
    rm -f build/DepthKey.dmg
    hdiutil create -quiet -volname DepthKey -srcfolder "$staging" -format UDZO build/DepthKey.dmg
    rm -rf "$staging"
    echo "Built build/DepthKey.dmg"
    ;;
  run)
    open build/DepthKey.app
    ;;
esac
