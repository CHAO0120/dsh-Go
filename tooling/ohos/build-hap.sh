#!/usr/bin/env bash
# Builds the HarmonyOS HAP from app/ohos with oh-flutter.
#
#   FLUTTER_OHOS=/path/to/flutter-ohos/bin/flutter tooling/ohos/build-hap.sh [--debug]
#
# The OHOS plugin overrides apply only for this run: pubspec_overrides.yaml and
# the lock file it changes are put back on exit, so the Android graph stays as it
# was. The host needs oh-flutter's AOT tools, published for macOS arm64 only so far
# (see app/ohos/README.md), plus hvigor and ohpm from HarmonyOS Command Line Tools.
set -euo pipefail

APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../app" && pwd)"
FLUTTER="${FLUTTER_OHOS:-flutter}"
MODE="${1:---release}"

cd "$APP"
LOCK="$(mktemp)"
cp pubspec.lock "$LOCK"
restore() {
  rm -rf pubspec_overrides.yaml ohos/.vendor
  cp "$LOCK" pubspec.lock
  rm -f "$LOCK"
}
trap restore EXIT

cp ohos/pubspec_overrides.ohos.yaml pubspec_overrides.yaml
"$FLUTTER" pub get
python3 "$APP/../tooling/ohos/vendor_platform_switches.py"
"$FLUTTER" pub get
"$FLUTTER" build hap "$MODE" --target-platform ohos-arm64
