#!/bin/zsh
# Builds Unfold.app (universal) and packs it into dist/Unfold.dmg
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Unfold.app
rm -rf build dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 \
    -framework AppKit -framework SwiftUI -framework IOKit -framework ServiceManagement \
    Sources/*.swift -o build/Unfold-$arch
done
lipo -create build/Unfold-arm64 build/Unfold-x86_64 -output "$APP/Contents/MacOS/Unfold"
rm build/Unfold-arm64 build/Unfold-x86_64

cp Resources/Info.plist "$APP/Contents/"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make_icon.swift Resources
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --deep --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"

STAGE=build/dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Unfold" -srcfolder "$STAGE" -ov -format UDZO dist/Unfold.dmg >/dev/null
echo "✓ dist/Unfold.dmg"
