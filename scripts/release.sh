#!/bin/bash
# Build a signed, notarized and stapled DMG into ./dist, ready to attach to a
# GitHub release.
#
#   NOTARY_PROFILE=<profile> scripts/release.sh
#
# <profile> is a notarytool credentials profile in your keychain. Create one
# once (you type the app-specific password yourself; it never leaves the
# keychain):
#   xcrun notarytool store-credentials <profile> --apple-id <you@example.com> --team-id <TEAMID>
set -euo pipefail
cd "$(dirname "$0")/.."
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile - see the comment at the top}"

APP_NAME="Accounts for Claude"
VERSION="$(cat VERSION)"
DMG="dist/AccountsForClaude-$VERSION.dmg"

scripts/build.sh
APP="build/$APP_NAME.app"

# Notarization only accepts Developer ID signatures with the hardened runtime.
IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -n 1)"
[ -n "$IDENTITY" ] || { echo "error: $APP is not signed with a Developer ID Application certificate" >&2; exit 1; }

# The DMG holds the app and a shortcut to /Applications to drag it onto.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
rm -f "$DMG" "$DMG.sha256"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "notarizing (usually a few minutes)..."
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# What Gatekeeper will say when someone downloads and opens it.
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
(cd dist && shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256")
echo "ready: $DMG"
cat "$DMG.sha256"
