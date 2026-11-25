#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
bridge_output="${1:-$native_dir/build}"
mkdir -p "$bridge_output"
python3 "$native_dir/generate-campaign-entities.py"
sdk=$(xcrun --show-sdk-path)
xcrun clang -O2 -Wall -Wextra -Werror -target arm64-apple-macos13.0 -isysroot "$sdk" -I "$sdk/usr/include/libxml2" -c "$native_dir/CampaignHTML.c" -o "$bridge_output/CampaignHTML.o"
