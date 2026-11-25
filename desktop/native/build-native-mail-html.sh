#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
helper="$native_dir/build/NextCRM Native.app/Contents/Helpers/NextCRM Mail Viewer.app"
mkdir -p "$helper/Contents/MacOS"
swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos13.0 -framework AppKit -framework WebKit "$native_dir/NativeMailHTML.swift" "$native_dir/NativeMailHTMLRenderer.swift" "$native_dir/NativeMailHTMLApp.swift" -o "$helper/Contents/MacOS/NextCRMMailViewer"
cp "$native_dir/NativeMailHTML-Info.plist" "$helper/Contents/Info.plist"
codesign --force --sign - "$helper"
codesign --verify --strict "$helper"
