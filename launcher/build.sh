#!/bin/bash
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Launcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Launcher "$APP/Contents/MacOS/Launcher"
cp Info.plist "$APP/Contents/Info.plist"
IDENTITY="-"
if security find-identity -p codesigning | grep -q "Suite MacBook"; then IDENTITY="Suite MacBook"; fi
codesign --force -s "$IDENTITY" "$APP"
pkill -x Launcher || true
rm -rf /Applications/Launcher.app
cp -R "$APP" /Applications/
# Abre sem as variáveis de sessão do Claude, caso o script rode de dentro dele
env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
    -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_CODE_EXECPATH -u CLAUDE_EFFORT -u AI_AGENT \
    open /Applications/Launcher.app
