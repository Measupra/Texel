#!/bin/bash
# Builds the Mac app signed with your Developer ID and notarized by Apple, so it opens on any Mac
# without the "can't be opened" / "Apple could not verify" warning.
#
#   bash build-notarized.sh     -> Texel.app and Texel.zip (upload the zip to GitHub)
#
# Needs: the full Xcode app, signed in (Xcode › Settings › Accounts) with your paid
# Apple Developer account. The first run asks for your Apple ID and an app-specific password
# (make one at account.apple.com › Sign-In and Security › App-Specific Passwords); they're
# saved in your Mac's keychain, so later runs don't ask again.
set -euo pipefail
cd "$(dirname "$0")"

TEAM_ID="${TEAM_ID:-YWGQ662D6B}"
PROFILE="texel-notary"
OUT="build/notarized"

osascript -e 'quit app "Xcode"' 2>/dev/null || true
sleep 2
if ls .pending/*.swift >/dev/null 2>&1; then cp .pending/*.swift App/; fi

XCG=".tools/xcodegen/bin/xcodegen"
if [ ! -x "$XCG" ]; then
  echo "XcodeGen is missing. Run  bash build-mac.sh  once first (it downloads it)."
  exit 1
fi
"$XCG" generate --spec project.yml --quiet

fail() {
  echo ""
  echo "$1 failed. The errors were:"
  grep -E "error:|Error" "$2" | sort -u | head -30 || true
  echo ""
  if grep -qiE "Developer ID|no signing certificate|no account|not a member|requires a development team" "$2"; then
    echo "This looks like a signing problem. In Xcode › Settings › Accounts, select your Apple ID,"
    echo "click Manage Certificates…, then + › Developer ID Application. Then run this again."
  fi
  echo "Full log: $(pwd)/$2"
  exit 1
}

# 1. Saved notarization login (asked once).
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "One-time setup: Apple needs your Apple ID and an app-specific password to notarize."
  echo "Make the password at account.apple.com › Sign-In and Security › App-Specific Passwords."
  echo ""
  xcrun notarytool store-credentials "$PROFILE" --team-id "$TEAM_ID"
fi

rm -rf "$OUT"
mkdir -p "$OUT"

# 2. Archive and sign with Developer ID.
echo "Building and signing the Mac app…"
xcodebuild -project TexelPhone.xcodeproj -scheme TexelMac -configuration Release \
  -destination "generic/platform=macOS" -archivePath "$OUT/Texel.xcarchive" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
  archive > "$OUT/archive.log" 2>&1 || fail "Building" "$OUT/archive.log"

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$OUT/Texel.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" \
  -allowProvisioningUpdates > "$OUT/export.log" 2>&1 || fail "Signing" "$OUT/export.log"
APP="$OUT/export/Texel.app"
[ -d "$APP" ] || { echo "Signed app not found. See $OUT/export.log"; exit 1; }

# 3. Send it to Apple and wait for the verdict (usually 2–10 minutes).
echo "Sending to Apple for notarization (usually a few minutes)…"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/upload.zip"
xcrun notarytool submit "$OUT/upload.zip" --keychain-profile "$PROFILE" --wait \
  --output-format plist > "$OUT/notary.plist" 2>"$OUT/notary.err" || true
STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" "$OUT/notary.plist" 2>/dev/null || echo "unknown")
if [ "$STATUS" != "Accepted" ]; then
  echo ""
  echo "Apple didn't accept it (status: $STATUS)."
  ID=$(/usr/libexec/PlistBuddy -c "Print :id" "$OUT/notary.plist" 2>/dev/null || true)
  if [ -n "$ID" ]; then
    xcrun notarytool log "$ID" --keychain-profile "$PROFILE" "$OUT/notary-log.json" >/dev/null 2>&1 || true
    echo "Apple's report: $(pwd)/$OUT/notary-log.json"
  fi
  cat "$OUT/notary.err" 2>/dev/null | head -10
  exit 1
fi

# 4. Attach Apple's approval to the app, so it opens even offline, and zip it for sharing.
xcrun stapler staple "$APP" >/dev/null
rm -rf Texel.app Texel.zip
cp -R "$APP" Texel.app
ditto -c -k --sequesterRsrc --keepParent Texel.app Texel.zip

echo ""
spctl -a -t exec -vv Texel.app 2>&1 | sed 's/^/  /'
echo ""
echo "Done: $(pwd)/Texel.zip"
echo "Upload Texel.zip to your GitHub release. It opens on any Mac without a warning."
