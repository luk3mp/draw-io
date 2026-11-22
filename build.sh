#!/bin/bash
# Builds Draw IO.app into ./build. Run `./build.sh install` to also copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

# Workaround for a Command Line Tools bug: an old leftover module.modulemap redefines
# `SwiftBridging` and breaks every build. This overlay hides it from the compiler only.
FIX="$PWD/toolchain-fix"
mkdir -p "$FIX"
: > "$FIX/empty.modulemap"
cat > "$FIX/overlay.yaml" <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [ {
    "type": "directory", "name": "/Library/Developer/CommandLineTools/usr/include/swift",
    "contents": [ { "type": "file", "name": "module.modulemap", "external-contents": "$FIX/empty.modulemap" } ]
} ] }
YAML

APP="build/Draw IO.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon: render once from Tools/MakeIcon.swift into Resources/AppIcon.icns.
if [[ ! -f Resources/AppIcon.icns ]]; then
    ICONTMP=$(mktemp -d)
    swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
        -vfsoverlay "$FIX/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$FIX/overlay.yaml" \
        -o "$ICONTMP/MakeIcon" Tools/MakeIcon.swift 2>/dev/null || \
    swiftc -target "$(uname -m)-apple-macosx14.0" \
        -vfsoverlay "$FIX/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$FIX/overlay.yaml" \
        -o "$ICONTMP/MakeIcon" Tools/MakeIcon.swift
    "$ICONTMP/MakeIcon" "$ICONTMP/icon.png"
    SET="$ICONTMP/AppIcon.iconset"; mkdir "$SET"
    for sz in 16 32 128 256 512; do
        sips -z $sz $sz "$ICONTMP/icon.png" --out "$SET/icon_${sz}x${sz}.png" >/dev/null
        sips -z $((sz*2)) $((sz*2)) "$ICONTMP/icon.png" --out "$SET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o Resources/AppIcon.icns
    rm -rf "$ICONTMP"
fi
swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -vfsoverlay "$FIX/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$FIX/overlay.yaml" \
    -o "$APP/Contents/MacOS/DrawIO" Sources/DrawIO/*.swift
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign with a stable local certificate (created once, kept in its own keychain) so macOS
# recognises rebuilds as the same app and keeps the Screen Recording permission.
# Ad-hoc signing (--sign -) would make every build look like a brand-new app.
IDENTITY="Draw IO Local Signing"
KEYCHAIN="$HOME/Library/Keychains/drawio-signing.keychain-db"
KEYCHAIN_PASS="drawio-local"   # only protects this local, signing-only keychain
if [[ ! -f "$KEYCHAIN" ]]; then
    echo "Creating local signing certificate (one time)…"
    TMP=$(mktemp -d)
    cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/id.p12" -passout pass:"$KEYCHAIN_PASS" 2>/dev/null
    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"   # don't auto-lock
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASS" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
    rm -rf "$TMP"
fi
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
# codesign only finds identities in the keychain search list, so add ours (keeping the existing ones).
if ! security list-keychains -d user | grep -q "drawio-signing"; then
    eval "security list-keychains -d user -s $(security list-keychains -d user | tr '\n' ' ') \"$KEYCHAIN\""
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x DrawIO || true
    rm -rf "/Applications/Draw IO.app"
    cp -R "$APP" /Applications/
    open "/Applications/Draw IO.app"
    echo "Installed to /Applications/Draw IO.app"
fi
