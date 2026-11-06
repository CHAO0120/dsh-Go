#!/usr/bin/env bash
# The normal app build has no optional Rust owner or associated resources.
set -euo pipefail
[[ "${DSH_PHONE_SELF_RUNNER_ENABLED:-NO}" == YES ]] || exit 0
: "${SRCROOT:?Xcode SRCROOT required}"
: "${TARGET_BUILD_DIR:?Xcode TARGET_BUILD_DIR required}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?Xcode resource path required}"
SOURCE="$SRCROOT/PhoneSelfRunnerNative"
DESTINATION="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/PhoneSelfRunnerNotices"
for name in LICENSE.idevice.txt THIRD_PARTY_CRATES.json SOURCE.json; do
  [[ -f "$SOURCE/$name" ]] || { printf 'Missing optional native notice: %s; rerun build-phone-self-runner.sh.\n' "$name" >&2; exit 1; }
done
mkdir -p "$DESTINATION"
for name in LICENSE.idevice.txt THIRD_PARTY_CRATES.json SOURCE.json; do
  cp "$SOURCE/$name" "$DESTINATION/$name"
done
