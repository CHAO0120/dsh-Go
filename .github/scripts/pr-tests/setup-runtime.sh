#!/usr/bin/env bash
# Always patch a disposable npm tree, never an installed DSH or a user profile.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
version="$(python3 - "$root/runtime/build-runtime.sh" <<'PY'
import re, sys
from pathlib import Path
source = Path(sys.argv[1]).read_text(encoding='utf-8')
match = re.search(r'^DSH_VERSION="\$\{DSH_VERSION:-([0-9A-Za-z.-]+)\}"', source, re.M)
if not match:
    raise SystemExit('Cannot determine the pinned DSH version')
print(match[1])
PY
)"
prefix="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dsh-ci-prefix.XXXXXX")"
lock="$root/runtime/locks/dsh-$version"
if [[ -f "$lock/package.json" && -f "$lock/package-lock.json" ]]; then
  cp "$lock/package.json" "$lock/package-lock.json" "$prefix/"
  npm ci --prefix "$prefix" --ignore-scripts --no-audit --no-fund
else
  # Source checkouts need not contain the build host's ignored lock cache.
  # Exact DSH version plus rtbuild's byte pins reject incompatible npm drift.
  npm install --prefix "$prefix" --save-exact --ignore-scripts --no-audit --no-fund "@deepseek-ai/dsh@$version"
fi
node - "$prefix" "$version" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const [prefix, version] = process.argv.slice(2);
const actual = JSON.parse(fs.readFileSync(path.join(prefix, 'node_modules/@deepseek-ai/dsh/package.json'), 'utf8')).version;
if (actual !== version) throw new Error(`DSH version mismatch: ${actual} != ${version}`);
JS
cp "$prefix/node_modules/@deepseek-ai/dsh-fs-local/lib/index.js" "$prefix/fs-local-original.js"
python3 -I "$root/runtime/lib/rtbuild.py" patch-dsh --prefix "$prefix" --dsh-version "$version"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'DSH_PREFIX=%s\nDSH_TEST_PREFIX=%s\nDSH_INSTALL=%s/node_modules/@deepseek-ai/dsh\nDSH_FS_LOCAL_ORIGINAL_JS=%s/fs-local-original.js\n' \
    "$prefix" "$prefix" "$prefix" "$prefix" >> "$GITHUB_ENV"
fi
printf 'Prepared isolated patched DSH: %s\n' "$prefix"
