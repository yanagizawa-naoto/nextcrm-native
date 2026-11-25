#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
mkdir -p "$native_dir/build"
swiftc -swift-version 5 -parse-as-library -O -framework AppKit -lsqlite3 "$native_dir/NativeDatabase.swift" "$native_dir/MailReview.swift" "$native_dir/CampaignMergeTags.swift" "$native_dir/CampaignRichText.swift" "$native_dir/CampaignRichTextTests.swift" -o "$native_dir/build/CampaignRichTextTests"
"$native_dir/build/CampaignRichTextTests"
