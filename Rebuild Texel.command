#!/bin/bash
# Double-click to apply Claude's latest changes and rebuild the Mac app.
cd "$(dirname "$0")"
echo "Closing Xcode and Texel so nothing overwrites the new files…"
osascript -e 'quit app "Xcode"' 2>/dev/null
killall Texel 2>/dev/null
sleep 3
if ls .pending/*.swift >/dev/null 2>&1; then
  cp .pending/*.swift App/
  echo "Applied the latest changes."
fi
if bash build-mac.sh; then
  open Texel.app
  echo ""
  echo "Texel is open. You can close this window."
else
  echo ""
  echo "The build failed. Copy the errors above and paste them to Claude."
fi
