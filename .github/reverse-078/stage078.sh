# reverse request 078: one prefix stage (temp branch only, never merged). usage: bash stage078.sh <ASTRICT|BREC|BSTRICT>
# From core20-076 stage076.sh with the 078 paths/values. Every stage: new empty prefix, copy of its own tree's rc.1 lock
# pair, exactly one
#   npm ci --prefix <prefix> --ignore-scripts --no-audit --no-fund   (npm_config_fetch_retries=0)
# then the pristine gate (official unpinned dsh-session-turn-outline lib/types/types.d.ts 2175 B / 79d16b1e... and the
# official lib/index.js before the Unicode pin 724f09b4...), then exactly one patch-dsh call from the tree root:
#   ASTRICT : strict with the ORIGINAL pins (tree A = TESTONLY), pins must stay byte-identical; 120/170/89 + types pristine;
#   BREC    : --record (tree B = FULL, original pins), then the typed whole-JSON sole-addition gate, the ordinary
#             whitespace gate on pins.json, the real-Git pins-only diff (--full-index --binary) and the tree gate
#             (complete diff minus the exact pins path == FULL);
#   BSTRICT : strict (no --record) with the recorded pins, which must stay byte-identical; 121/172/90.
# ASTRICT and BSTRICT then create their two isolation directories (TMPDIR, DSH_HOME) directly, empty.
# npm/patch-dsh stdout and stderr go straight from timeout(1) into their own files; wrapper metadata goes to the step
# log and wrapper-078.log. Any non-zero step stops at once; no retry, no rollback, no rebuild.
set +e
. "$RUNNER_TEMP/common078.sh"
S=$1; O="$RUNNER_TEMP/out"; ID="$RUNNER_TEMP/ident078.py"; IDJ="$RUNNER_TEMP/raw/078-identities.json"; V=0.2.2-rc.1
FULLRAW="$RUNNER_TEMP/raw/2622-turn-outline-first-human-FULL-NOPINS-LF.patch"
TORAW="$RUNNER_TEMP/raw/2622-turn-outline-first-human-TESTONLY-LF.patch"
case "$S" in
  ASTRICT) T="$RUNNER_TEMP/tree-A"; P="$RUNNER_TEMP/prefix-A-strict"; IT="$RUNNER_TEMP/iso-A-tmpdir"; IH="$RUNNER_TEMP/iso-A-dsh-home" ;;
  BREC) T="$RUNNER_TEMP/tree-B"; P="$RUNNER_TEMP/prefix-B-record" ;;
  BSTRICT) T="$RUNNER_TEMP/tree-B"; P="$RUNNER_TEMP/prefix-B-strict"; IT="$RUNNER_TEMP/iso-B-tmpdir"; IH="$RUNNER_TEMP/iso-B-dsh-home" ;;
  *) echo "unknown stage $S"; exit 2 ;;
esac
log "=== STAGE $S BEGIN $(now) tree=$T prefix=$P"
[ -d "$T" ] || { log "NO_TREE $T"; log "PREP_STOPPED rc=1"; exit 1; }
[ ! -e "$P" ] && [ ! -L "$P" ] || { log "PREFIX_EXISTS $P"; log "PREP_STOPPED rc=1"; exit 1; }
cd "$T" || exit 1
if [ "$S" = ASTRICT ]; then
  run 120 python3 -I "$ID" post "$T" "$TORAW" a PRE_STRICT_A "$O/diff-A-pre-strict.patch" "$O/status-A-pre-strict.txt" "$IDJ"
  run 10 cp runtime/patches/pins.json "$O/pins-original-A.json"
elif [ "$S" = BREC ]; then
  run 120 python3 -I "$ID" post "$T" "$FULLRAW" b PRE_RECORD "$O/diff-B-pre-record.patch" "$O/status-B-pre-record.txt" "$IDJ"
  run 60 python3 -I "$ID" prerecord "$T"
  run 10 cp runtime/patches/pins.json "$O/pins-original-B.json"
else
  run 120 python3 -I "$ID" post "$T" "$FULLRAW" brec PRE_STRICT_B "$O/diff-B-pre-strict.patch" "$O/status-B-pre-strict.txt" "$IDJ"
  run 10 cmp runtime/patches/pins.json "$O/pins-recorded-B.json"
fi
run 10 mkdir "$P"
run 10 cp runtime/locks/dsh-$V/package.json runtime/locks/dsh-$V/package-lock.json "$P/"
capture NPM_CI 300 "$O/npm-ci-$S" env npm_config_fetch_retries=0 npm ci --prefix "$P" --ignore-scripts --no-audit --no-fund
rc=$?
echo "--- npm-ci-$S.stdout ($(wc -c < "$O/npm-ci-$S.stdout") B) ---"; cat "$O/npm-ci-$S.stdout"
echo "--- npm-ci-$S.stderr ($(wc -c < "$O/npm-ci-$S.stderr") B) ---"; cat "$O/npm-ci-$S.stderr"; echo "--- end ---"
[ $rc -eq 0 ] || { log "PREP_STOPPED rc=$rc (npm ci failed; no retry)"; exit $rc; }
run 60 python3 -I "$ID" pristine "$P" "$S"
if [ "$S" = BREC ]; then
  capture PATCH_DSH_RECORD 180 "$O/patch-dsh-$S" python3 -I runtime/lib/rtbuild.py patch-dsh --prefix "$P" --dsh-version "$V" --record
else
  capture PATCH_DSH 180 "$O/patch-dsh-$S" python3 -I runtime/lib/rtbuild.py patch-dsh --prefix "$P" --dsh-version "$V"
fi
rc=$?
echo "--- patch-dsh-$S.stdout ($(wc -l < "$O/patch-dsh-$S.stdout") lines) ---"; cat "$O/patch-dsh-$S.stdout"
echo "--- patch-dsh-$S.stderr ($(wc -c < "$O/patch-dsh-$S.stderr") B) ---"; cat "$O/patch-dsh-$S.stderr"; echo "--- end ---"
if [ "$S" = BREC ]; then
  # Preserve the actual recorded JSON whatever happened (read-only copy outside the tree).
  cp runtime/patches/pins.json "$O/pins-recorded-B.json"
  log "RECORDED_PINS_COPY bytes=$(wc -c < "$O/pins-recorded-B.json") sha256=$(sha256sum "$O/pins-recorded-B.json" | cut -c1-64)"
fi
[ $rc -eq 0 ] || { log "PREP_STOPPED rc=$rc (patch-dsh failed; no retry)"; exit $rc; }
if [ "$S" = ASTRICT ]; then
  run 60 python3 -I "$ID" patchlog "$T" "$O/patch-dsh-$S.stdout" strict "$S"
  run 120 python3 -I "$ID" prefix "$T" "$P" a "$S" "$IDJ" "$(sha256sum "$O/pins-original-A.json" | cut -c1-64)"
  run 10 cmp runtime/patches/pins.json "$O/pins-original-A.json"
  run 120 python3 -I "$ID" post "$T" "$TORAW" a AFTER_STRICT_A "$O/diff-A-after-strict.patch" "$O/status-A-after-strict.txt" "$IDJ"
elif [ "$S" = BREC ]; then
  run 60 python3 -I "$ID" pins "$O/pins-original-B.json" "$O/pins-recorded-B.json" "$IDJ"
  run 60 git -c core.autocrlf=false -C "$T" diff --check -- runtime/patches/pins.json
  capture PINS_ONLY_DIFF 60 "$O/diff-B-pins-only" git -c core.autocrlf=false -C "$T" diff --full-index --binary --no-ext-diff "$BASE" -- runtime/patches/pins.json
  rc=$?; log "PINS_ONLY_DIFF bytes=$(wc -c < "$O/diff-B-pins-only.stdout") sha256=$(sha256sum "$O/diff-B-pins-only.stdout" | cut -c1-64) stderr_bytes=$(wc -c < "$O/diff-B-pins-only.stderr")"
  [ $rc -eq 0 ] || { log "PREP_STOPPED rc=$rc (pins-only diff)"; exit $rc; }
  run 120 python3 -I "$ID" post "$T" "$FULLRAW" brec RECORDED "$O/diff-B-after-record.patch" "$O/status-B-after-record.txt" "$IDJ"
  run 60 python3 -I "$ID" patchlog "$T" "$O/patch-dsh-$S.stdout" record "$S"
  run 120 python3 -I "$ID" prefix "$T" "$P" b "$S" "$IDJ" "$(sha256sum "$O/pins-recorded-B.json" | cut -c1-64)"
else
  run 60 python3 -I "$ID" patchlog "$T" "$O/patch-dsh-$S.stdout" strict "$S"
  run 120 python3 -I "$ID" prefix "$T" "$P" b "$S" "$IDJ" "$(sha256sum "$O/pins-recorded-B.json" | cut -c1-64)"
  run 10 cmp runtime/patches/pins.json "$O/pins-recorded-B.json"
fi
if [ "$S" != BREC ]; then
  [ ! -e "$IT" ] && [ ! -L "$IT" ] && [ ! -e "$IH" ] && [ ! -L "$IH" ] || { log "ISOLATION_EXISTS $IT $IH"; log "PREP_STOPPED rc=1"; exit 1; }
  run 10 mkdir "$IT" "$IH"
  log "ISOLATION TMPDIR=$IT entries=$(find "$IT" -mindepth 1 | wc -l) DSH_HOME=$IH entries=$(find "$IH" -mindepth 1 | wc -l) HOME=$HOME (unchanged)"
fi
log "=== STAGE $S OK $(now)"
exit 0
