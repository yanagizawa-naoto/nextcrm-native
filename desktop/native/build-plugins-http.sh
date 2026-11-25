#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
bridge_output="${1:-$native_dir/build}"
mkdir -p "$bridge_output"
plugin_sdk_path=$(xcrun --show-sdk-path)
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -target arm64-apple-macos13.0 -isysroot "$plugin_sdk_path" -c "$native_dir/NativePluginsHTTP.c" -o "$bridge_output/NativePluginsHTTP.o"
