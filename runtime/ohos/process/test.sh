#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
: "${OHOS_TEST_PROCESS_PREFIX:?指定仅应用 OHOS 进程补丁的独立 DSH 前缀}"
: "${OHOS_TEST_BASE_PREFIX:?指定未修改的 npm-ci DSH 前缀}"
: "${OHOS_SIM_PRELOAD:?指定已通过复核的 O0 sim/preload.mjs}"
node_bin=${NODE:-node}
"$node_bin" -e 'if (process.version !== "v24.22.1") throw new Error("本轮测量固定 Node 24.22.1")'
DSH_GO_OHOS_SIM=1 "$node_bin" --test --test-isolation=none "$repo/runtime/tests/ohos/process-android-path.test.mjs"
"$node_bin" "$repo/runtime/ohos/process/build-rg-regex.mjs" "${OHOS_ESBUILD_PREFIX:-$repo/runtime/ohos/node/build-tools}"
python3 "$repo/runtime/ohos/process/build-just-bash.py"
tests=("$repo/runtime/tests/ohos/process.test.mjs" "$repo/runtime/tests/ohos/process-integration.test.mjs" "$repo/runtime/tests/ohos/process-policy.test.mjs" "$repo/runtime/tests/ohos/process-diagnostics.test.mjs")
env -u DSH_GO_OHOS_SIM M4_DIAGNOSTICS_MODE=jit "$node_bin" --import "$repo/runtime/ohos/sim/marker.mjs" --test --test-isolation=none "${tests[@]}"
env -u DSH_GO_OHOS_SIM M4_DIAGNOSTICS_MODE=strict DSH_GO_OHOS_SIM_PLATFORM=openharmony DSH_GO_OHOS_SIM_ADDONS='[]' "$node_bin" --jitless --import "$OHOS_SIM_PRELOAD" --test --test-isolation=none "${tests[@]}"
