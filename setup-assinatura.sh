#!/bin/bash
set -e
cd "$(dirname "$0")"
NAME="Suite MacBook"
OLD="Launcher Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if ! security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    TMP=$(mktemp -d)
    cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" -extensions ext
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/$NAME.p12" -passout pass:suite -name "$NAME"
    security import "$TMP/$NAME.p12" -k "$KEYCHAIN" -P suite -T /usr/bin/codesign
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
    rm -rf "$TMP"
fi

bash launcher/build.sh
bash alternador/build.sh
bash topbar/build.sh

pkill -x Launcher || true
pkill -x Alternador || true
pkill -x Topbar || true
for s in Accessibility SystemPolicyAllFiles Location AppleEvents; do
    tccutil reset $s com.alanvieira.launcher || true
    tccutil reset $s com.alan.alternador || true
    tccutil reset $s com.alanvieira.topbar || true
done

while security find-certificate -c "$OLD" "$KEYCHAIN" >/dev/null 2>&1; do
    security delete-identity -c "$OLD" "$KEYCHAIN" 2>/dev/null || security delete-certificate -c "$OLD" "$KEYCHAIN"
done

open /Applications/Launcher.app
open /Applications/Alternador.app
open /Applications/Topbar.app
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
