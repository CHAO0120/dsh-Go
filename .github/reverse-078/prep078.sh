# reverse request 078: prepare the two new complete e5d product trees (temp branch only, never merged).
# From core20-076 prep076.sh with the 078 paths. usage: bash prep078.sh <A|B>  (A = TESTONLY, B = FULL-NOPINS)
# Fresh detached worktree at the fixed base -> identity pre (ten fixed base inputs, five direct-import lock rows, 120-diff
# order and blobs) -> apply --check (once) -> apply (once; stdout/stderr of both kept in their own files, warnings
# returned verbatim) -> git add -N only for the frozen NEW paths of the group (A: new test; B: new inner + new test; the
# modified Unicode test is tracked) -> the frozen path-scoped whitespace gates (both test paths ordinary; B also the exact
# new 22z inner with core.whitespace=-space-before-tab) -> identity post (whole diff vs base == raw byte-for-byte, full
# status, all final file identities, A 120 diffs / B 121 with the new inner at rank 90). Nothing is committed.
# Any non-zero stops this group at once.
set +e
. "$RUNNER_TEMP/common078.sh"
G=$1; O="$RUNNER_TEMP/out"; ID="$RUNNER_TEMP/ident078.py"; IDJ="$RUNNER_TEMP/raw/078-identities.json"
INNER=runtime/patches/zzzzzzzzzzzzzzzzzzzzzz-turn-outline-first-human.diff
TEST=runtime/tests/turn-outline-first-human.test.mjs
UNI=runtime/tests/turn-outline-unicode.test.mjs
case "$G" in
  A) T="$RUNNER_TEMP/tree-A"; RAWP="$RUNNER_TEMP/raw/2622-turn-outline-first-human-TESTONLY-LF.patch"; grp=a; NEWP="$TEST" ;;
  B) T="$RUNNER_TEMP/tree-B"; RAWP="$RUNNER_TEMP/raw/2622-turn-outline-first-human-FULL-NOPINS-LF.patch"; grp=b; NEWP="$INNER $TEST" ;;
  *) echo "unknown group $G"; exit 2 ;;
esac
log "=== PREP TREE $G BEGIN $(now) base=$BASE raw=$(basename "$RAWP") tree=$T"
[ ! -e "$T" ] && [ ! -L "$T" ] || { log "TREE_EXISTS $T"; log "PREP_STOPPED rc=1"; exit 1; }
run 120 git -c core.autocrlf=false worktree add --detach "$T" "$BASE"
run 120 python3 -I "$ID" pre "$T" "$IDJ"
capture APPLY_CHECK_$G 60 "$O/apply-check-$G" git -c core.autocrlf=false -C "$T" apply --check "$RAWP"; rc=$?
echo "--- apply-check-$G stdout/stderr ---"; cat "$O/apply-check-$G.stdout" "$O/apply-check-$G.stderr"; echo "--- end ---"
[ $rc -eq 0 ] || { log "PREP_STOPPED rc=$rc"; exit $rc; }
capture APPLY_$G 60 "$O/apply-$G" git -c core.autocrlf=false -C "$T" apply "$RAWP"; rc=$?
echo "--- apply-$G stdout/stderr ---"; cat "$O/apply-$G.stdout" "$O/apply-$G.stderr"; echo "--- end ---"
[ $rc -eq 0 ] || { log "PREP_STOPPED rc=$rc"; exit $rc; }
# shellcheck disable=SC2086
run 60 git -c core.autocrlf=false -C "$T" add -N -- $NEWP
run 60 git -c core.autocrlf=false -C "$T" diff --check -- "$TEST" "$UNI"
if [ "$G" = B ]; then run 60 git -c core.autocrlf=false -c core.whitespace=-space-before-tab -C "$T" diff --check -- "$INNER"; fi
run 120 python3 -I "$ID" post "$T" "$RAWP" "$grp" "PREP_$G" "$O/diff-$G-prep.patch" "$O/status-$G-prep.txt" "$IDJ"
log "TREE $G HEAD=$(git -c core.autocrlf=false -C "$T" rev-parse HEAD)"
log "=== PREP TREE $G OK $(now)"
exit 0
