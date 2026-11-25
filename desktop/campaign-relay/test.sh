#!/bin/zsh
set -euo pipefail
relay_dir="${0:A:h}"
mkdir -p "$relay_dir/../native/build"
node "$relay_dir/../native/campaign-events-reference.cjs"
node --test "$relay_dir/relay.test.cjs"
