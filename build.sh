#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP="build/Voxly.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -Xlinker -S -file-prefix-map "$PWD"=. Sources/main.swift -o "$APP/Contents/MacOS/Voxly" -framework Cocoa -framework AVFoundation -framework Speech
cp Info.plist "$APP/Contents/Info.plist"; mkdir -p "$APP/Contents/Resources"; cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "OK -> $APP"
