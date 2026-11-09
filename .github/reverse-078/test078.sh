# reverse request 078: read-only pre-gates, exactly one node --test call, read-only post gates (temp branch only).
# usage: bash test078.sh <A|B>. From core20-076 test076.sh with the 078 values: Node TERM 110 s + KILL 10 s = 120 s
# (min with the job deadline), A = 3 new cases on tree A / prefix-A-strict / original pins, B = 3 new + 9 legacy Unicode
# cases on tree B / prefix-B-strict / recorded pins. DSH_TEST_PREFIX and DSH_PREFIX are both set inline to the stage
# prefix (both must be unset in the step env). Node's stdout and stderr are redirected straight from timeout(1) into
# node-<G>.stdout / node-<G>.stderr; no wrapper function runs inside that redirection. Wrapper metadata goes to the step
# log and wrapper-078.log. Each gate keeps its own exit-code file; post gates run whatever the test result was. The
# test's real exit code goes to node-<G>-exit.txt and the step output "rc"; the result gate is a later step.
# No retry, no set -e, no "|| true", no pipes or tee around node, no --test-force-exit, no name filter.
set +e
. "$RUNNER_TEMP/common078.sh"
G=$1; O="$RUNNER_TEMP/out"; ID="$RUNNER_TEMP/ident078.py"; IDJ="$RUNNER_TEMP/raw/078-identities.json"
case "$G" in
  A) T="$RUNNER_TEMP/tree-A"; P="$RUNNER_TEMP/prefix-A-strict"; IT="$RUNNER_TEMP/iso-A-tmpdir"; IH="$RUNNER_TEMP/iso-A-dsh-home"
     RAWP="$RUNNER_TEMP/raw/2622-turn-outline-first-human-TESTONLY-LF.patch"; grp=a; pg=a; PREF="$O/pins-original-A.json"
     FILES="runtime/tests/turn-outline-first-human.test.mjs" ;;
  B) T="$RUNNER_TEMP/tree-B"; P="$RUNNER_TEMP/prefix-B-strict"; IT="$RUNNER_TEMP/iso-B-tmpdir"; IH="$RUNNER_TEMP/iso-B-dsh-home"
     RAWP="$RUNNER_TEMP/raw/2622-turn-outline-first-human-FULL-NOPINS-LF.patch"; grp=brec; pg=b; PREF="$O/pins-recorded-B.json"
     FILES="runtime/tests/turn-outline-first-human.test.mjs runtime/tests/turn-outline-unicode.test.mjs" ;;
  *) echo "unknown group $G"; exit 2 ;;
esac
PSHA=$(sha256sum "$PREF" | cut -c1-64)
cd "$T" || { log "NO_TREE $T"; exit 2; }
iso_gate() {  # $1 = label; prints the listing; returns 0 only if both dirs exist, are not symlinks and are empty
  local nt nh
  if [ ! -d "$IT" ] || [ -L "$IT" ] || [ ! -d "$IH" ] || [ -L "$IH" ]; then
    log "ISOLATION_${G}_$1 missing or symlink: $IT $IH"; return 1; fi
  nt=$(find "$IT" -mindepth 1 | wc -l); nh=$(find "$IH" -mindepth 1 | wc -l)
  log "ISOLATION_${G}_$1 TMPDIR=$IT entries=$nt DSH_HOME=$IH entries=$nh"
  find "$IT" "$IH" -mindepth 1 -printf '%y %s %p\n' > "$O/isolation-$G-$1-listing.txt"
  echo "--- $1 TMPDIR/DSH_HOME content (find -mindepth 1; full listing in isolation-$G-$1-listing.txt) ---"
  head -200 "$O/isolation-$G-$1-listing.txt"
  echo "--- end ---"
  [ "$nt" -eq 0 ] && [ "$nh" -eq 0 ]
}
pins_gate() {  # tree pins.json must stay byte-identical to the preserved pins JSON of this group
  gate_run 10 cmp runtime/patches/pins.json "$PREF"; local r=$?
  log "PINS_UNCHANGED_${G}_$1 cmp_exit=$r ($(basename "$PREF"))"; return $r
}
# ---------------- pre-gates ----------------
pre=0
if [ -n "${DSH_PREFIX+x}" ]; then log "PRE_DSH_PREFIX_GATE=FAIL (already set to '$DSH_PREFIX' in the step env)"; pre=1; else log "PRE_DSH_PREFIX_GATE=PASS (unset in the step env)"; fi
if [ -n "${DSH_TEST_PREFIX+x}" ]; then log "PRE_DSH_TEST_PREFIX_GATE=FAIL (already set to '$DSH_TEST_PREFIX' in the step env)"; pre=1; else log "PRE_DSH_TEST_PREFIX_GATE=PASS (unset in the step env)"; fi
iso_gate PRE; r1=$?; echo "$r1" > "$O/pre-isolation-$G-exit.txt"; log "PRE_ISOLATION_${G}_EXIT=$r1"
gate_run 120 python3 -I "$ID" post "$T" "$RAWP" "$grp" "PRETEST_$G" "$O/diff-$G-pretest.patch" "$O/status-$G-pretest.txt" "$IDJ"; r2=$?
echo "$r2" > "$O/pre-tree-ident-$G-exit.txt"; log "PRE_TREE_IDENT_${G}_EXIT=$r2"
gate_run 120 python3 -I "$ID" prefix "$T" "$P" "$pg" "PRETEST_$G" "$IDJ" "$PSHA"; r3=$?
echo "$r3" > "$O/pre-prefix-ident-$G-exit.txt"; log "PRE_PREFIX_IDENT_${G}_EXIT=$r3"
pins_gate PRE; r4=$?; echo "$r4" > "$O/pre-pins-$G-exit.txt"
if [ $pre -ne 0 ] || [ $r1 -ne 0 ] || [ $r2 -ne 0 ] || [ $r3 -ne 0 ] || [ $r4 -ne 0 ]; then log "PRE_GATES_$G=FAIL -> command NOT_RUN"; exit 5; fi
log "PRE_GATES_$G=PASS"
# ---------------- the only product command of this stage ----------------
log "CWD=$(pwd) NODE_BIN=$(command -v node) EUID=$(id -u) HOME=$HOME UV_USE_IO_URING=${UV_USE_IO_URING-unset}"
lim=$(wd_limit 110)  # TERM at <=110 s, KILL 10 s later: the Node target is hard-bounded at 120 s
if [ "$lim" -le 0 ]; then log "WATCHDOG: deadline reached; command NOT_RUN"; exit 125; fi
log "+ DSH_TEST_PREFIX=$P DSH_PREFIX=$P TMPDIR=$IT DSH_HOME=$IH node --test --test-reporter=tap --test-concurrency=1 $FILES (under timeout --kill-after=10s ${lim}s)"
S0=$(date +%s.%N); log "=== CMD_$G BEGIN $(now) (invocation 1 of 1) WATCHDOG limit=${lim}s"
# shellcheck disable=SC2086
timeout --kill-after=10s "${lim}s" env DSH_TEST_PREFIX="$P" DSH_PREFIX="$P" TMPDIR="$IT" DSH_HOME="$IH" node --test --test-reporter=tap --test-concurrency=1 $FILES > "$O/node-$G.stdout" 2> "$O/node-$G.stderr"
rc=$?
S1=$(date +%s.%N)
log "=== CMD_$G END $(now) CMD_EXIT=$rc seconds=$(awk -v a="$S0" -v b="$S1" 'BEGIN{printf "%.3f", b-a}') invocations=1"
if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then log "WATCHDOG_FIRED_$G rc=$rc"; else log "WATCHDOG_FIRED_$G=no"; fi
echo "$rc" > "$O/node-$G-exit.txt"
echo "rc=$rc" >> "$GITHUB_OUTPUT"
echo "--- STDOUT $(wc -c < "$O/node-$G.stdout") B $(wc -l < "$O/node-$G.stdout") lines sha256=$(sha256sum "$O/node-$G.stdout" | cut -c1-64) ---"
cat "$O/node-$G.stdout"
echo "--- STDERR $(wc -c < "$O/node-$G.stderr") B sha256=$(sha256sum "$O/node-$G.stderr" | cut -c1-64) ---"
cat "$O/node-$G.stderr"
echo "--- END ---"
# ---------------- post gates (read-only, whatever the result) ----------------
iso_gate AFTER; a1=$?; echo "$a1" > "$O/post-isolation-$G-exit.txt"; log "POST_ISOLATION_${G}_EXIT=$a1"
gate_run 120 python3 -I "$ID" post "$T" "$RAWP" "$grp" "AFTER_$G" "$O/diff-$G-after.patch" "$O/status-$G-after.txt" "$IDJ"; a2=$?
echo "$a2" > "$O/post-tree-ident-$G-exit.txt"; log "POST_TREE_IDENT_${G}_EXIT=$a2"
gate_run 120 python3 -I "$ID" prefix "$T" "$P" "$pg" "AFTER_$G" "$IDJ" "$PSHA"; a3=$?
echo "$a3" > "$O/post-prefix-ident-$G-exit.txt"; log "POST_PREFIX_IDENT_${G}_EXIT=$a3"
pins_gate AFTER; a4=$?; echo "$a4" > "$O/post-pins-$G-exit.txt"
if [ $rc -eq 124 ] || [ $rc -eq 137 ] || [ $a1 -ne 0 ] || [ $a2 -ne 0 ] || [ $a3 -ne 0 ] || [ $a4 -ne 0 ]; then log "POST_GATES_$G=FAIL"; exit 6; fi
log "POST_GATES_$G=PASS"
exit 0
