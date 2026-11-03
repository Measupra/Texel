#!/bin/bash
# Builds the Mac version of Texel (same interface as the iPhone app) into Texel.app here.
# Needs the full Xcode app. Afterwards you can also open TexelPhone.xcodeproj, pick the
# TexelMac scheme and My Mac, and press Run.
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "This needs the full Xcode app. Install it, then run:"
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

XCG_VERSION="2.44.1"
XCG_SHA256="a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73"
TOOLS=".tools"
XCG="$TOOLS/xcodegen/bin/xcodegen"
if [ ! -x "$XCG" ]; then
  echo "Downloading XcodeGen $XCG_VERSION…"
  mkdir -p "$TOOLS"
  curl -fsSL -o "$TOOLS/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCG_VERSION/xcodegen.zip"
  if ! echo "$XCG_SHA256  $TOOLS/xcodegen.zip" | shasum -a 256 -c - >/dev/null 2>&1; then
    echo "The XcodeGen download didn't match its expected checksum. Delete the .tools folder and try again."
    exit 1
  fi
  unzip -q -o "$TOOLS/xcodegen.zip" -d "$TOOLS"
fi

echo "Updating TexelPhone.xcodeproj (adds the TexelMac target)…"
"$XCG" generate --spec project.yml --quiet

echo "Building Texel for Mac (a few minutes the first time)…"
mkdir -p build/mac
if ! xcodebuild -project TexelPhone.xcodeproj -scheme TexelMac -configuration Release \
      -destination 'platform=macOS' -derivedDataPath build/mac/DerivedData \
      CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
      build > build/mac/build.log 2>&1; then
  echo ""
  echo "The build failed. The errors were:"
  grep -E "error:" build/mac/build.log | sort -u | head -40 || true
  echo ""
  echo "Full log: $(pwd)/build/mac/build.log"
  exit 1
fi

APP="build/mac/DerivedData/Build/Products/Release/Texel.app"
if [ ! -d "$APP" ]; then
  echo "The build finished but Texel.app wasn't where expected. See build/mac/build.log."
  exit 1
fi
rm -rf Texel.app
cp -R "$APP" Texel.app

# A zip for sharing (e.g. a GitHub release). ditto keeps the permissions and signature intact;
# zips made other ways can drop the "executable" flag, and then the app won't open on other Macs.
rm -f Texel.zip
ditto -c -k --sequesterRsrc --keepParent Texel.app Texel.zip

echo ""
echo "Done: $(pwd)/Texel.app"
echo "Open it with:  open Texel.app   or drag it into /Applications."
echo "To share it, upload Texel.zip (not a zip you make yourself)."
