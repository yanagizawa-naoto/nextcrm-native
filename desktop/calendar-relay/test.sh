#!/bin/zsh
set -euo pipefail
relay_dir="${0:A:h}"
node "$relay_dir/../native/calendly-reference.cjs"
node --test "$relay_dir/relay.test.cjs"
