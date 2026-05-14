#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
REPO="$PWD"

APP_NAME="Caffeine That Keeps You Active On Teams For Mac"
BIN_NAME="caffeine-that-keeps-you-active-on-teams-for-mac"
LABEL="com.kevin.caffeine-that-keeps-you-active-on-teams-for-mac"

APP="$HOME/Applications/$APP_NAME.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "→ creating app bundle at $APP"
mkdir -p "$APP/Contents/MacOS"

echo "→ building binary"
"$REPO/build.sh" >/dev/null  # build.sh prints its own TCC warning; we'll reprint at the end

echo "→ installing LaunchAgent at $AGENT"
mkdir -p "$(dirname "$AGENT")"
sed "s|__HOME__|$HOME|g" "$REPO/LaunchAgent.plist" > "$AGENT"

echo "→ (re)loading LaunchAgent"
launchctl unload "$AGENT" 2>/dev/null || true
launchctl load "$AGENT"

NEW_HASH=$(codesign -dvvv "$APP" 2>&1 | awk -F= '/CDHash/{print $2; exit}')

cat <<DONE

================================================================
  installed
================================================================
  App:          $APP
  LaunchAgent:  $AGENT
  Log:          ~/Library/Logs/$BIN_NAME.log
  cdhash:       ${NEW_HASH:-unknown}

  NEXT: grant Accessibility
    System Settings → Privacy & Security → Accessibility
    Add "$APP"

  Then restart the process so launchd respawns it under the grant:
    pkill -f '$BIN_NAME'

  Confirm it's working:
    tail -f ~/Library/Logs/$BIN_NAME.log
    # while toggled on, expect a jiggle line every 30s with moved=true
================================================================
DONE
