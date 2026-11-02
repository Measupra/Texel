#!/bin/bash
# Builds Texel.ipa (unsigned) for iPhone and iPad, next to this script.
# Needs the full Xcode app. Sign and install it with Sideloadly or AltStore,
# or open TexelPhone.xcodeproj in Xcode and press Run with your iPhone plugged in.
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  echo "Building for iPhone needs the full Xcode app (the Command Line Tools aren't enough)."
  echo "  1. Install Xcode from the Mac App Store."
  echo "  2. Open it once and let it install the iOS platform (Xcode › Settings › Components)."
  echo "  3. Run:  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  echo "Then run this script again."
  exit 1
fi

XCG_VERSION="2.44.1"
XCG_SHA256="a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73"
TOOLS=".tools"
XCG="$TOOLS/xcodegen/bin/xcodegen"
if [ ! -x "$XCG" ]; then
  echo "Downloading XcodeGen $XCG_VERSION (makes the Xcode project)…"
  mkdir -p "$TOOLS"
  curl -fsSL -o "$TOOLS/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCG_VERSION/xcodegen.zip"
  if ! echo "$XCG_SHA256  $TOOLS/xcodegen.zip" | shasum -a 256 -c - >/dev/null 2>&1; then
    echo "The XcodeGen download didn't match its expected checksum. Delete the .tools folder and try again."
    exit 1
  fi
  unzip -q -o "$TOOLS/xcodegen.zip" -d "$TOOLS"
fi

# Optional: pass your own bundle ID if Xcode says the default one is taken,
#   BUNDLE_ID=com.yourname.texel bash build-ipa.sh
if [ -n "${BUNDLE_ID:-}" ]; then
  sed -i '' "s/PRODUCT_BUNDLE_IDENTIFIER: .*/PRODUCT_BUNDLE_IDENTIFIER: $BUNDLE_ID/" project.yml
fi

echo "Generating TexelPhone.xcodeproj…"
"$XCG" generate --spec project.yml --quiet

echo "Building for iPhone (a few minutes the first time)…"
rm -rf build/ios
mkdir -p build/ios
if ! xcodebuild -project TexelPhone.xcodeproj -scheme TexelPhone -configuration Release \
      -sdk iphoneos -destination 'generic/platform=iOS' \
      -derivedDataPath build/ios/DerivedData \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
      build > build/ios/build.log 2>&1; then
  echo ""
  echo "The build failed. The errors were:"
  grep -E "error:" build/ios/build.log | sort -u | head -40 || true
  echo ""
  echo "Full log: $(pwd)/build/ios/build.log"
  exit 1
fi

APP="build/ios/DerivedData/Build/Products/Release-iphoneos/Texel.app"
if [ ! -d "$APP" ]; then
  echo "The build finished but Texel.app wasn't where expected. See build/ios/build.log."
  exit 1
fi

echo "Packaging Texel.ipa…"
mkdir -p build/ios/Payload
cp -R "$APP" build/ios/Payload/
rm -f Texel.ipa
(cd build/ios && zip -qry ../../Texel.ipa Payload)

echo ""
echo "Done: $(pwd)/Texel.ipa ($(du -h Texel.ipa | cut -f1))"
echo "Install it with Sideloadly or AltStore using your Apple ID."
