#!/usr/bin/env bash
# 未在 Apple 上编译. Build-only iSH dependency; does not activate a guest backend.
# build-ish.sh iphoneos|iphonesimulator|linux OUTPUT_DIR
# build-ish.sh --cache-key SDK     (local inputs only; no download)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/ish/build.py" "$@"
