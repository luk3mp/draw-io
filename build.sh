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
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x DrawIO || true
    rm -rf "/Applications/Draw IO.app"
    cp -R "$APP" /Applications/
    open "/Applications/Draw IO.app"
    echo "Installed to /Applications/Draw IO.app"
fi
