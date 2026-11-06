#!/bin/bash
# Build "Accounts for Claude.app" (menu bar only, universal arm64 + x86_64) into ./build.
#
#   scripts/build.sh            build
#   scripts/build.sh install    build, copy to /Applications (or ~/Applications), and open it
#
# Signing: uses the first "Developer ID Application" certificate in your
# keychain, with the hardened runtime that notarization needs. Without one it
# signs ad-hoc, which is fine for running it on your own Mac.
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"  pick a certificate
#   SIGN_IDENTITY=-                                          force ad-hoc
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Accounts for Claude"
BIN="AccountsForClaude"
BUNDLE_ID="io.github.prjwrld.accounts-for-claude"
VERSION="$(cat VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/$APP_NAME.app"
CACHE="${TMPDIR:-/tmp}/accounts-for-claude-module-cache"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
    swiftc -O -module-name "$BIN" \
        -target "$arch-apple-macos14.4" \
        -module-cache-path "$CACHE" \
        Sources/*.swift -o "build/$BIN-$arch"
done
lipo -create "build/$BIN-arm64" "build/$BIN-x86_64" -output "$APP/Contents/MacOS/$BIN"
rm -f "build/$BIN-arm64" "build/$BIN-x86_64"

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>          <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>           <string>$BIN</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>              <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>       <string>14.4</string>
    <key>LSUIElement</key>                  <true/>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>     <string>MIT licence. Unofficial; not affiliated with Anthropic.</string>
</dict>
</plist>
PLIST

if [ -z "${SIGN_IDENTITY+x}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
        sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)"
fi
if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
    echo "signed: $SIGN_IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "signed: ad-hoc (no Developer ID certificate found)"
fi
echo "built: $APP $VERSION ($BUILD_NUMBER), $(du -sh "$APP" | cut -f1)"

if [ "${1:-}" = "install" ]; then
    DEST="/Applications"
    [ -w "$DEST" ] || DEST="$HOME/Applications"
    mkdir -p "$DEST"
    pkill -x "$BIN" 2>/dev/null || true
    rm -rf "$DEST/$APP_NAME.app"
    cp -R "$APP" "$DEST/"
    open "$DEST/$APP_NAME.app"
    echo "installed: $DEST/$APP_NAME.app - look for the Claude logo in the menu bar."
fi
