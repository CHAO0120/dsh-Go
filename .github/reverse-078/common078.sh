# reverse request 078 shared shell helpers (temp branch only, never merged). Sourced by the stage scripts.
# Copied from core20-076 common076.sh; only the wrapper log name (wrapper-078.log) and this header changed. 076 notes:
# log() writes to the step log stderr and $WRAPLOG (no tee); gate_run() is the watchdog for read-only gates that must not
# stop the script. DEADLINE comes from the workflow first step: min(job start - 30 s + 20 min, 2026-11-09T02:25:06Z).
#   wd_limit CAP  -> prints only the number of seconds allowed: min(CAP, seconds left before DEADLINE minus 20 s),
#                    or 0 when the deadline is reached. Called as $(wd_limit N), outside any capture redirection.
#   log MSG...    -> wrapper metadata: step log (stderr) and $WRAPLOG; never a captured npm/patch-dsh/Node file.
#   run CAP cmd   -> uncaptured helper (git, identity checks, mkdir, cp); stops the script on any non-zero exit.
#   gate_run CAP cmd -> read-only gate under the watchdog; returns the exit code (125 = deadline, not started).
#   capture LABEL CAP OUTBASE cmd -> the one invocation of a tool, stdout/stderr redirected straight from timeout(1).
# timeout(1) runs without --verbose (writes nothing); 124/137 mark a watchdog stop; it only touches its own child tree.
DEADLINE_EPOCH=$(date -u -d "$DEADLINE" +%s)
WRAPLOG="$RUNNER_TEMP/out/wrapper-078.log"
now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
log() { printf '%s\n' "$*" >> "$WRAPLOG"; printf '%s\n' "$*" >&2; }
wd_limit() {
  local cap=$1 left=$(( DEADLINE_EPOCH - $(date -u +%s) - 20 ))
  if [ "$left" -le 0 ]; then echo 0; elif [ "$left" -lt "$cap" ]; then echo "$left"; else echo "$cap"; fi
}
run() {
  local cap=$1; shift
  local lim; lim=$(wd_limit "$cap")
  log "+ $* [$(now)] WATCHDOG limit=${lim}s (cap ${cap}s, deadline $DEADLINE)"
  if [ "$lim" -le 0 ]; then log "  WATCHDOG: deadline reached; not starting"; log "PREP_STOPPED rc=125"; exit 125; fi
  timeout --kill-after=10s "${lim}s" "$@"; local rc=$?
  log "  EXIT=$rc [$(now)]"
  if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then log "  WATCHDOG_FIRED rc=$rc"; fi
  [ $rc -eq 0 ] || { log "PREP_STOPPED rc=$rc"; exit $rc; }
}
gate_run() {
  local cap=$1; shift
  local lim; lim=$(wd_limit "$cap")
  log "+ $* [$(now)] WATCHDOG limit=${lim}s (cap ${cap}s, deadline $DEADLINE)"
  if [ "$lim" -le 0 ]; then log "  WATCHDOG: deadline reached; gate NOT_RUN rc=125"; return 125; fi
  timeout --kill-after=10s "${lim}s" "$@"; local rc=$?
  log "  GATE_EXIT=$rc [$(now)]"
  if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then log "  WATCHDOG_FIRED rc=$rc"; fi
  return $rc
}
capture() {
  local label=$1 cap=$2 base=$3; shift 3
  local lim; lim=$(wd_limit "$cap")
  log "+ $* [$(now)] WATCHDOG limit=${lim}s (invocation 1 of 1, cwd=$(pwd)) -> $(basename "$base").stdout/.stderr"
  if [ "$lim" -le 0 ]; then log "  WATCHDOG: deadline reached; $label NOT_RUN"; echo 125 > "$base-exit.txt"; return 125; fi
  timeout --kill-after=10s "${lim}s" "$@" > "$base.stdout" 2> "$base.stderr"
  local rc=$?
  echo "$rc" > "$base-exit.txt"
  log "  ${label}_EXIT=$rc [$(now)]"
  if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then log "  WATCHDOG_FIRED rc=$rc"; fi
  return $rc
}
