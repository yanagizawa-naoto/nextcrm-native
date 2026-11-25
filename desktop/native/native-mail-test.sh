#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
mkdir -p "$native_dir/build"
mail_build=$(mktemp -d "$native_dir/build/native-mail-test.XXXXXX")
function finish_mail_build() {
  local result=$?
  python3 "$native_dir/native_mail_build.py" verify "$native_dir" "$mail_build" "$0" --exit "$result"
  local verification=$?
  rm -rf "$mail_build/cache"
  if (( result != 0 )); then return "$result"; fi
  return "$verification"
}
trap finish_mail_build EXIT
python3 "$native_dir/native_mail_build.py" build "$native_dir" "$mail_build" "$0"
python3 "$native_dir/native-mail-transport-test.py"
node "$native_dir/native-mail-address-reference.cjs" "$native_dir/build/native-mail-address-reference.json"
swiftc -swift-version 5 -parse-as-library -O -lcurl -lsqlite3 -lxml2 -module-cache-path "$mail_build/cache" -import-objc-header "$native_dir/NativeMailParsing.h" "$mail_build/NativeMailTransport.o" "$mail_build/CampaignHTML.o" "$native_dir/NativeMailTemporaryFiles.swift" "$native_dir/NativeMail.swift" "$native_dir/NativeMailHTMLText.swift" "$native_dir/NativeMailMIME.swift" "$native_dir/NativeMailIMAP.swift" "$native_dir/NativeMailMIMESpool.swift" "$native_dir/NativeMailTextHTML.swift" "$native_dir/NativeMailIMAPFile.swift" "$native_dir/NativeMailSpool.swift" "$native_dir/NativeMailClient.swift" "$native_dir/NativeMailTests.swift" -o "$mail_build/NativeMailTests"
"$mail_build/NativeMailTests" "$native_dir"
