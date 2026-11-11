#!/bin/bash
set -e
cd "$(dirname "$0")"
APP=Alternador.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/Alternador" -framework Cocoa -framework ApplicationServices
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.alan.alternador</string>
  <key>CFBundleName</key><string>Alternador</string>
  <key>CFBundleExecutable</key><string>Alternador</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Ler o endereço das abas do Safari para mostrar o ícone de cada site no Cmd+Tab.</string>
</dict>
</plist>
EOF
IDENTITY="-"
if security find-identity -p codesigning | grep -q "Suite MacBook"; then IDENTITY="Suite MacBook"; fi

pkill -f "/Applications/$APP/Contents/MacOS/Alternador" || true
rm -rf "/Applications/$APP"
cp -R "$APP" /Applications/
# Assina a cópia em /Applications: a pasta Documents está no iCloud, que recoloca atributos no app.
xattr -cr "/Applications/$APP"
codesign --force -s "$IDENTITY" "/Applications/$APP"
open "/Applications/$APP"
echo "OK: instalado em /Applications/$APP"
