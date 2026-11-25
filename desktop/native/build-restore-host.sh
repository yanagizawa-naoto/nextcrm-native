#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
mkdir -p "$native_dir/build"
sdk=$(xcrun --show-sdk-path)
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -target arm64-apple-macos13.0 -isysroot "$sdk" -c "$native_dir/NativeRestoreHostBridge.c" -o "$native_dir/build/NativeRestoreHostBridge.o"
