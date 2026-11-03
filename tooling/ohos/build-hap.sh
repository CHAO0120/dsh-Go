#!/usr/bin/env bash
# Builds the HarmonyOS HAP from app/ohos with oh-flutter.
#
#   FLUTTER_OHOS=/path/to/flutter-ohos/bin/flutter \
#   DSH_OHOS_NATIVE_LIBS=/path/to/hap-libs/arm64-v8a DSH_NODE_HEADERS=/path/to/node-v24.22.1/src \
#   DSH_OHOS_RUNTIME=/path/to/dsh-runtime-rawfile.zip \
#     tooling/ohos/build-hap.sh [--debug]
#
# The OHOS plugin overrides apply only for this run: pubspec_overrides.yaml and
# the lock file it changes are put back on exit, so the Android graph stays as it
# was. The host needs oh-flutter's AOT tools, published for macOS arm64 only so far
# (see app/ohos/README.md), plus hvigor and ohpm from HarmonyOS Command Line Tools.
#
# The Node-side native libraries come from runtime/ohos/native/build-hap-libs.py and are placed only for this run.
# The runtime is one Stored dsh-runtime/runtime.zip, which the app streams from rawfile; it is never expanded here.
set -euo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../app" && pwd)"
FLUTTER="${FLUTTER_OHOS:-flutter}"
MODE="${1:---release}"
NATIVE_LIBS="${DSH_OHOS_NATIVE_LIBS:?Set DSH_OHOS_NATIVE_LIBS to the arm64-v8a directory from build-hap-libs.py}"
: "${DSH_NODE_HEADERS:?Set DSH_NODE_HEADERS to the pinned Node source src directory}"
RUNTIME="${DSH_OHOS_RUNTIME:?Set DSH_OHOS_RUNTIME to the zip from runtime/ohos/package/compose-runtime.py}"
RUNTIME="$(cd "$(dirname "$RUNTIME")" && pwd)/$(basename "$RUNTIME")"
[[ -f "$RUNTIME" ]] || { printf 'Missing runtime zip: %s\n' "$RUNTIME" >&2; exit 1; }
PREBUILT=(libnode.so libdsh_flock.so libdsh_require_builtin.so)
for lib in "${PREBUILT[@]}"; do
  [[ -f "$NATIVE_LIBS/$lib" ]] || { printf 'Missing native library: %s\n' "$NATIVE_LIBS/$lib" >&2; exit 1; }
done

cd "$APP"
LIBS=ohos/entry/libs/arm64-v8a
RAWFILE=ohos/entry/src/main/resources/rawfile
LOCK="$(mktemp)"
cp pubspec.lock "$LOCK"
restore() {
  rm -rf pubspec_overrides.yaml ohos/.vendor
  for lib in "${PREBUILT[@]}"; do rm -f "$LIBS/$lib"; done
  rmdir "$LIBS" ohos/entry/libs 2>/dev/null || true
  rm -rf "$RAWFILE/dsh-runtime"
  rmdir "$RAWFILE" 2>/dev/null || true
  cp "$LOCK" pubspec.lock
  rm -f "$LOCK"
}
trap restore EXIT

mkdir -p "$LIBS"
for lib in "${PREBUILT[@]}"; do cp "$NATIVE_LIBS/$lib" "$LIBS/$lib"; done
mkdir -p "$RAWFILE"
python3 -I - "$RUNTIME" "$RAWFILE" <<'PY_RUNTIME_ARCHIVE'
import pathlib, sys, zipfile
transport, rawfile = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
with zipfile.ZipFile(transport) as bundle:
    entries = bundle.infolist()
    if (len(entries) != 1 or entries[0].filename != "dsh-runtime/runtime.zip"
            or entries[0].compress_type != zipfile.ZIP_STORED
            or entries[0].flag_bits & 9):
        sys.exit(f"{transport} must contain one unencrypted Stored dsh-runtime/runtime.zip")
    bundle.extract(entries[0], rawfile)
PY_RUNTIME_ARCHIVE
export DSH_NODE_HEADERS
cp ohos/pubspec_overrides.ohos.yaml pubspec_overrides.yaml
"$FLUTTER" pub get
python3 "$APP/../tooling/ohos/vendor_platform_switches.py"
"$FLUTTER" pub get
# No icon tree shaking: oh-flutter's const_finder fails on its own Dart ("Invalid SDK hash").
"$FLUTTER" build hap "$MODE" --target-platform ohos-arm64 --no-tree-shake-icons
