#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.local/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.local/module-cache"
swift run --disable-sandbox --cache-path .local/swiftpm-cache --config-path .local/swiftpm-config --security-path .local/swiftpm-security -Xswiftc -enable-testing bolbhai-checks
