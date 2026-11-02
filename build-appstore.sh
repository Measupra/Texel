#!/bin/bash
# Builds Texel for the App Store: a signed Texel.ipa (iPhone/iPad) and Texel.pkg (Mac),
# both with the same version so they ship as one listing (Universal Purchase).
#
#   bash build-appstore.sh            -> makes AppStore/Texel.ipa and AppStore/Texel.pkg
#   UPLOAD=1 bash build-appstore.sh   -> builds and uploads both straight to App Store Connect
#
# Needs the full Xcode app, signed in (Xcode › Settings › Accounts) with an Apple ID that
# belongs to the paid Apple Developer Program.
set -euo pipefail
cd "$(dirname "$0")"

TEAM_ID="${TEAM_ID:-YWGQ662D6B}"
VERSION="${VERSION:-1.0}"
# Every upload needs a new build number; a timestamp always goes up.
BUILD="${BUILD:-$(date +%y%m%d%H%M)}"
DEST="export"
[ "${UPLOAD:-0}" = "1" ] && DEST="upload"

osascript -e 'quit app "Xcode"' 2>/dev/null || true
sleep 2
if ls .pending/*.swift >/dev/null 2>&1; then cp .pending/*.swift App/; fi

XCG=".tools/xcodegen/bin/xcodegen"
if [ ! -x "$XCG" ]; then
  echo "XcodeGen is missing. Run bash build-mac.sh once first (it downloads it)."
  exit 1
fi
"$XCG" generate --spec project.yml --quiet

mkdir -p build/appstore AppStore
cat > build/appstore/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>$DEST</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
PLIST

fail() {
  echo ""
  echo "$1 failed. The errors were:"
  grep -E "error:|Error " "$2" | sort -u | head -30 || true
  echo ""
  if grep -qiE "no account|no signing certificate|requires a development team|not a member|Provisioning profile|Team .* is not|Apple Developer Program" "$2"; then
    echo "This looks like a signing problem. Check that:"
    echo "  - your Apple ID is in the paid Apple Developer Program,"
    echo "  - Xcode › Settings › Accounts is signed in with it,"
    echo "  - the team ID is right (run again with TEAM_ID=YOURTEAMID bash build-appstore.sh)."
  fi
  echo "Full log: $(pwd)/$2"
  exit 1
}

build() {   # scheme, platform destination, label
  local scheme="$1" dest="$2" label="$3"
  local archive="build/appstore/$scheme.xcarchive"
  echo "Archiving $label (version $VERSION, build $BUILD)…"
  xcodebuild -project TexelPhone.xcodeproj -scheme "$scheme" -configuration Release \
    -destination "$dest" -archivePath "$archive" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    archive > "build/appstore/$scheme-archive.log" 2>&1 || fail "Archiving $label" "build/appstore/$scheme-archive.log"

  if [ "$DEST" = "upload" ]; then echo "Uploading $label to App Store Connect…"; else echo "Exporting $label…"; fi
  rm -rf "build/appstore/$scheme-export"
  xcodebuild -exportArchive -archivePath "$archive" \
    -exportOptionsPlist build/appstore/ExportOptions.plist \
    -exportPath "build/appstore/$scheme-export" \
    -allowProvisioningUpdates \
    > "build/appstore/$scheme-export.log" 2>&1 || fail "Exporting $label" "build/appstore/$scheme-export.log"
}

build TexelPhone "generic/platform=iOS" "iPhone & iPad"
build TexelMac "generic/platform=macOS" "Mac"

echo ""
if [ "$DEST" = "upload" ]; then
  echo "Done. Both builds were uploaded to App Store Connect (version $VERSION, build $BUILD)."
  echo "They appear under your app's TestFlight tab after Apple finishes processing them (usually minutes)."
else
  cp build/appstore/TexelPhone-export/*.ipa AppStore/Texel.ipa
  cp build/appstore/TexelMac-export/*.pkg AppStore/Texel.pkg
  echo "Done:"
  echo "  $(pwd)/AppStore/Texel.ipa   (iPhone & iPad)"
  echo "  $(pwd)/AppStore/Texel.pkg   (Mac)"
  echo "Upload both with Apple's free Transporter app, or run:  UPLOAD=1 bash build-appstore.sh"
fi
