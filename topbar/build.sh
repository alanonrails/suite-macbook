#!/bin/bash
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Topbar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Topbar "$APP/Contents/MacOS/Topbar"
cp Info.plist "$APP/Contents/Info.plist"
IDENTITY="-"
if security find-identity -p codesigning | grep -q "Suite MacBook"; then IDENTITY="Suite MacBook"; fi
xattr -cr "$APP"
codesign --force -s "$IDENTITY" "$APP"
pkill -x Topbar || true
rm -rf /Applications/Topbar.app
cp -R "$APP" /Applications/
env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
    -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_CODE_EXECPATH -u CLAUDE_EFFORT -u AI_AGENT \
    open /Applications/Topbar.app
echo "OK: /Applications/Topbar.app"
