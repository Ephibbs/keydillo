#!/bin/zsh
# Builds a Developer ID signed, notarized and stapled keydillo.app plus a zip for download.
# Needs: the "Developer ID Application" certificate in the login keychain, and notarytool credentials stored as
# the keychain profile "keydillo-notary" (xcrun notarytool store-credentials keydillo-notary …). No secrets here.
set -euo pipefail
cd "$(dirname "$0")/../App"
OUT=../release; rm -rf $OUT; mkdir -p $OUT
ID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
[[ -n $ID ]] || { echo "No Developer ID Application certificate in the keychain."; exit 1; }
echo "Signing as: $ID"

# iPhone approvals need the iCloud (CloudKit) entitlement, so releases build from the iCloud spec.
xcodegen generate --spec project.icloud.yml >/dev/null
xcodebuild -project Keydillo.xcodeproj -scheme Keydillo -configuration Release -archivePath $OUT/keydillo.xcarchive \
  -allowProvisioningUpdates archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"
xcodebuild -exportArchive -archivePath $OUT/keydillo.xcarchive -exportPath $OUT -exportOptionsPlist ../scripts/ExportOptions.plist \
  -allowProvisioningUpdates | grep -E "error:|EXPORT (SUCCEEDED|FAILED)"
APP=$OUT/keydillo.app

# The kd/keydillo command lives in Resources/bin: make sure it carries the Developer ID signature too, then reseal the app.
codesign --force --options runtime --timestamp --sign "$ID" "$APP/Contents/Resources/bin/keydillo"
codesign --force --options runtime --timestamp --sign "$ID" --preserve-metadata=entitlements,requirements,flags "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" $OUT/keydillo.zip
xcrun notarytool submit $OUT/keydillo.zip --keychain-profile keydillo-notary --wait
xcrun stapler staple "$APP"
rm $OUT/keydillo.zip && ditto -c -k --keepParent "$APP" $OUT/keydillo.zip
spctl -a -vv "$APP"

# The drag-to-Applications disk image (needs `brew install create-dmg`; it lays out the window through Finder).
command -v create-dmg >/dev/null || { echo "Install create-dmg: brew install create-dmg"; exit 1; }
BG=$OUT/dmg-background; mkdir -p $BG
swift ../scripts/dmg-background.swift $BG >/dev/null
tiffutil -cathidpicheck $BG/background.png $BG/background@2x.png -out $BG/background.tiff >/dev/null
mkdir -p $OUT/dmg-src && ditto "$APP" $OUT/dmg-src/keydillo.app
create-dmg --volname "keydillo" --background $BG/background.tiff --window-pos 200 120 --window-size 660 422 \
  --icon-size 128 --text-size 13 --icon "keydillo.app" 180 185 --hide-extension "keydillo.app" \
  --app-drop-link 480 185 --no-internet-enable $OUT/keydillo.dmg $OUT/dmg-src >/dev/null
rm -rf $OUT/dmg-src $BG
codesign --force --timestamp --sign "$ID" $OUT/keydillo.dmg
xcrun notarytool submit $OUT/keydillo.dmg --keychain-profile keydillo-notary --wait
xcrun stapler staple $OUT/keydillo.dmg
spctl -a -vv -t open --context context:primary-signature $OUT/keydillo.dmg
echo "Done: $OUT/keydillo.zip and $OUT/keydillo.dmg"
