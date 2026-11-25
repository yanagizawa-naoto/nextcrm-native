#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
zsh "$native_dir/build-campaign-html.sh"
node "$native_dir/campaign-html-reference.cjs"
swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos13.0 -lsqlite3 -lxml2 -import-objc-header "$native_dir/CampaignHTML.h" "$native_dir/build/CampaignHTML.o" "$native_dir/NativeDatabase.swift" "$native_dir/MailReview.swift" "$native_dir/CampaignMergeTags.swift" "$native_dir/CampaignHTML.swift" "$native_dir/CampaignHTMLTests.swift" -o "$native_dir/build/CampaignHTMLTests"
"$native_dir/build/CampaignHTMLTests" "$native_dir/build"
node "$native_dir/campaign-html-verify.cjs"
