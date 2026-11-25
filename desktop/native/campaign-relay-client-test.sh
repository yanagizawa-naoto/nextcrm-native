#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
mkdir -p "$native_dir/build"
swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos13.0 "$native_dir/CampaignRelayClient.swift" "$native_dir/CampaignRelayClientTests.swift" -o "$native_dir/build/CampaignRelayClientTests"
"$native_dir/build/CampaignRelayClientTests" "$native_dir"
