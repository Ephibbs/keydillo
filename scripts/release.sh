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

xcodegen generate >/dev/null
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
echo "Done: $OUT/keydillo.zip"
