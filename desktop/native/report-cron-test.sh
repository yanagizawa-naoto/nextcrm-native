#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
mkdir -p "$native_dir/build"
swiftc -swift-version 5 -parse-as-library -O "$native_dir/NativeReportCron.swift" "$native_dir/NativeReportCronTests.swift" -o "$native_dir/build/NativeReportCronTests"
"$native_dir/build/NativeReportCronTests"
