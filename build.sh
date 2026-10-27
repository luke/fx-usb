#!/bin/sh
set -eu
cd "$(dirname "$0")"
bundle='dist/FX-USB.app'
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" .swift-cache
xcrun swiftc -swift-version 5 -O -module-cache-path .swift-cache -target arm64-apple-macosx13.0 Sources/main.swift Sources/UI.swift Sources/FeedbackGuard.swift Sources/Buttons.swift Sources/Assistants.swift -o "$bundle/Contents/MacOS/FXMic"
cp Info.plist "$bundle/Contents/Info.plist"
cp Sources/fxmic_reader.py "$bundle/Contents/Resources/"
iconset="$(mktemp -d)/AppIcon.iconset"
"$bundle/Contents/MacOS/FXMic" --iconset "$iconset"
iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$bundle"
"$bundle/Contents/MacOS/FXMic" --self-test
