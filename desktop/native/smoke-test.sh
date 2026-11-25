#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
mkdir -p "$native_dir/build"
scratch="$(mktemp -d "$native_dir/build/public-smoke.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/tmp"
export TMPDIR="$scratch/tmp/"
python3 "$native_dir/generate-catalog.py"
python3 - "$scratch" <<'PY'
from pathlib import Path
import json, subprocess, sys
p = Path(sys.argv[1]).resolve()
q = lambda s: json.dumps(str(s))
home = Path.home()
darwin_tmp = Path(subprocess.check_output(['getconf', 'DARWIN_USER_TEMP_DIR'], text=True).strip()).resolve()
profile = '(version 1)\n(allow default)\n(deny network*)\n(deny file-write*)\n'
profile += '(allow file-write* (subpath ' + q(p) + ') (subpath ' + q(darwin_tmp) + ') (literal "/dev/null") (subpath "/dev/fd"))\n'
for relative in ['Library/Keychains', 'Library/Application Support/NextCRMNative', 'Library/Application Support/NextCRM']:
    profile += '(deny file-read* (subpath ' + q(home / relative) + '))\n'
profile += '(deny mach-lookup (global-name "com.apple.securityd"))\n'
(p / 'sandbox.sb').write_text(profile)
PY
swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$scratch/module-cache" -lsqlite3 \
  "$native_dir/AccountStore.swift" "$native_dir/StoreTests.swift" -o "$scratch/StoreTests"
/usr/bin/sandbox-exec -f "$scratch/sandbox.sb" "$scratch/StoreTests"
swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$scratch/module-cache" -lsqlite3 \
  "$native_dir/NativeDatabase.swift" "$native_dir/MailReview.swift" "$native_dir/DatabaseTests.swift" -o "$scratch/DatabaseTests"
/usr/bin/sandbox-exec -f "$scratch/sandbox.sb" "$scratch/DatabaseTests" "$native_dir"
