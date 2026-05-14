#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Caffeine That Keeps You Active On Teams For Mac"
BIN_NAME="caffeine-that-keeps-you-active-on-teams-for-mac"

APP="$HOME/Applications/$APP_NAME.app"
BIN_IN_APP="$APP/Contents/MacOS/$BIN_NAME"

echo "→ ensuring bundle structure at $APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

echo "→ compiling $BIN_NAME.swift"
swiftc -O "$BIN_NAME.swift" -o "$BIN_NAME"

echo "→ installing binary into $BIN_IN_APP"
cp "$BIN_NAME" "$BIN_IN_APP"

echo "→ re-signing (ad-hoc)"
codesign --force --sign - "$APP"

NEW_HASH=$(codesign -dvvv "$APP" 2>&1 | awk -F= '/CDHash/{print $2; exit}')

cat <<WARN

================================================================
  REBUILD INVALIDATES TCC ACCESSIBILITY GRANT
================================================================
  This app is ad-hoc signed. TCC pins the Accessibility grant
  to the binary's cdhash, and rebuilding changed it. The grant
  row still exists but will silently drop CGEvent posts — logs
  will show moved=false.

  New cdhash: ${NEW_HASH:-unknown}

  To re-enable:
    1. System Settings → Privacy & Security → Accessibility
    2. Remove "$APP_NAME" (minus button)
    3. Re-add "$APP"
    4. Restart the process so launchd respawns it under the
       fresh grant:

         pkill -f '$BIN_NAME'

  Then confirm with:
    tail -f ~/Library/Logs/$BIN_NAME.log
    # expect lines with moved=true while toggled on
================================================================
WARN
