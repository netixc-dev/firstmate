#!/usr/bin/env bash
# Shared watcher fixture mechanics for the triage and declared-wait suites.
# Sourced after each suite initializes ROOT, WATCH, DRAIN, and TMP_ROOT.

size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

# Common watcher knobs: tight poll/grace, no check or heartbeat cadence unless a
# test overrides them, so a test only exercises the path it targets. FM_CREW_STATE_BIN
# points at the case's hermetic fake fm-crew-state.sh (installed by make_case) so the
# absorb-only-when-provably-working triage reads a canned verdict; a test fixes that
# verdict via FM_FAKE_CREW_STATE in its environment before calling watch_bg.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

# Wait until <pid>'s watcher has completed a whole poll cycle, or exited first.
# A fixed wait_live budget only proves the process is still ALIVE: fm-watch.sh
# does bounded startup work (the recovery-marker snapshot, lock acquisition)
# before its first stale scan, so on a loaded
# machine a short fixed budget can reap a round before the cycle it asserts on
# ever ran - and then every "no wake, no marker" assertion passes vacuously
# while every "marker written" assertion fails spuriously.
# The liveness beacon is touched at the TOP of every poll, so this drops any
# beacon left by an earlier round, waits for THIS watcher to write a fresh one
# (some poll's top), then waits for that one to advance (the next poll's top) -
# and the whole cycle in between is what the caller's assertions describe.
# 0 if the watcher is still alive after a completed cycle, 1 if it exited.
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Every wait_for_exit budget in this file is 100 ticks (10s), not because any
# watcher takes that long to decide, but because fm-watch.sh does bounded
# startup work before its first poll: a tighter budget reaps the process while
# it is still starting and reports a spurious "did not surface" failure. A
# generous budget can only remove that false negative - a watcher that never
# exits still fails the assertion when the budget runs out.
wait_numeric_file() {
  local file=$1 limit=${2:-30} i=0 value
  while [ "$i" -lt "$limit" ]; do
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in
      ''|*[!0-9]*) ;;
      *) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Portable mtime in epoch seconds. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see fm-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Set <file>'s mtime to exactly <epoch> seconds, for aging a busy-turn marker by
# a precise amount (touch -t takes a local-time stamp, not an epoch, on both
# platforms, so convert via BSD `date -r` or GNU `date -d @`).
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  local reported size ident
  case "$1" in
    *.status)
      reported=$(status_observed_signature "$1")
      size=$(size_of "$1")
      ident=$(_fm_open_decisions_file_ident "$1")
      printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
      ;;
    *)
      if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
      ;;
  esac
}

# Prime <file>'s .seen-* suppressor to its CURRENT signature, so the per-poll
# no-verb signal scan (which watches every *.turn-ended for a size:mtime change)
# treats a just-created or just-backdated turn-ended marker as already seen.
# Busy-turn-age fixtures create/backdate turn-ended directly (there is no real
# harness touching it), so without this the marker's own first sighting would
# fire an unrelated "signal:" wake and mask the busy-turn-age assertion under
# test. Call again after any further touch/set_mtime on the same file.
prime_turnend_seen() {  # <file>
  local f=$1 base
  base=$(basename "$f" | tr '.' '_')
  printf '%s' "$(seen_sig "$f")" > "$(dirname "$f")/.seen-$base"
}

record_pi_busy() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source pi-ext --event agent-start
}

# Stop an owned watcher. TERM must end it through its EXIT cleanup, so one still
# alive after the file's standard 100-tick budget fails the case here, with the
# process evidence wait_for_exit prints, instead of an unbounded wait hanging
# the whole suite until the CI job timeout.
reap() {
  local rc
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100
  rc=$?
  [ "$rc" -ne 124 ] || fail "watcher pid $1 did not exit within 10s of TERM"
}


parked_watch_round() {  # <state> <fakebin> <out> <capture> <window> <exit|absorb>
  local state=$1 fakebin=$2 out=$3 capture=$4 window=$5 mode=$6 pid cycles=0
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · parked' \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if [ "$mode" = exit ]; then
    wait_for_exit "$pid" 100 || { reap "$pid"; return 1; }
    return 0
  fi
  while [ "$cycles" -lt 4 ]; do
    wait_poll_cycle "$state" "$pid" 300 || { reap "$pid"; return 1; }
    cycles=$((cycles + 1))
  done
  reap "$pid"
  return 0
}

wedge_threshold_round() {  # <state> <fakebin> <out> <capture> <window> <verdict> <exit|absorb>
  local state=$1 fakebin=$2 out=$3 capture=$4 window=$5 verdict=$6 mode=$7 pid cycles=0
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_CONFIG_OVERRIDE="$(dirname "$state")/config" \
    FM_FAKE_TMUX_CURRENT_COMMAND="${FM_TEST_PANE_COMMAND-grok}" \
    FM_FAKE_TMUX_WINDOWS="${FM_TEST_TMUX_WINDOWS-}" FM_FAKE_CREW_STATE="$verdict" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS="${FM_TEST_PAUSE_RESURFACE:-999}" FM_STALE_ESCALATE_SECS="${FM_TEST_STALE_ESCALATE:-1}" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if [ "$mode" = exit ]; then
    wait_for_exit "$pid" 100 || { reap "$pid"; return 1; }
    return 0
  fi
  while [ "$cycles" -lt 3 ]; do
    wait_poll_cycle "$state" "$pid" 300 || { reap "$pid"; return 1; }
    cycles=$((cycles + 1))
  done
  reap "$pid"
  return 0
}

wedge_threshold_fixture() {  # <name> <status-log> <status-age-secs> [<wedge-timer-age-secs>]
  local name=$1 log=$2 age=$3 timer=${4-} dir state statusf window key text back
  dir=$(make_case "$name"); state="$dir/state"
  window="test:fm-wedge"
  statusf="$state/wedge.status"
  text='waiting at the gate'
  printf '%s' "$text" > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/wedge.meta"
  printf '%s\n' "$log" > "$statusf"
  back=$(( $(date +%s) - age ))
  set_mtime "$back" "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-wedge_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "$text")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Already surfaced once, as it is after the supervision turn that handled the
  # first sight: the suppressor holds this exact hash, so every further poll goes
  # straight to the wedge timer.
  printf '%s' "$(hash_text "$text")" > "$state/.stale-$key"
  if [ -n "$timer" ]; then
    printf '%s\n' "$(( $(date +%s) - timer ))" > "$state/.stale-since-$key"
  fi
  # An UNCONFIGURED home: the config dir exists and is empty, so every case here
  # starts with the parked-gate wait evidence off and has to arm it deliberately.
  mkdir -p "$dir/config"
  printf '%s\n' "$dir"
}

arm_parked_gate() {  # <case-dir>
  : > "$1/config/wedge-defer-parked-gate"
}

wedge_stale_wakes() {  # <state> <window>
  awk -F '\t' -v w="$2" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

wedge_reported_wait_secs() {  # <watch-out>
  sed -n 's/.*waiting \([0-9][0-9]*\)s.*/\1/p' "$1" | head -1
}

run_malformed_wait_record_round() {  # <name> <evidence-body>
  local name=$1 body=$2 dir state out
  dir=$(make_case "$name"); state="$dir/state"
  printf 'working: validation under way\n' > "$state/wedge.status"
  printf '%s\n' "$(( $(date +%s) - 600 ))" > "$state/.stale-since-test_fm-wedge"

  out="$dir/defer.out"
  FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_WEDGE_DEMAND_INSPECT_COUNT=3 \
    bash -c '
      # shellcheck disable=SC1090,SC1091
      . "$1"
      wake() { :; }
      # A live agent, so the dead-record probe that runs after a refused
      # deferral keeps the unchanged ladder rather than reading a backend this
      # child shell has none of.
      fm_backend_agent_state() { printf alive; }
      eval "wedge_wait_evidence() { $2 ; }"
      wedge_timer_check "test:fm-wedge" "$FM_STATE_OVERRIDE/.stale-since-test_fm-wedge" \
        "non-terminal stale" "$FM_STATE_OVERRIDE/.wedge-escalations-test_fm-wedge" wedge \
        malformed-record-pane
    ' _ "$WATCH" "$body" > "$out" 2>&1 \
    || fail "the wedge timer failed on a malformed wait record ($name): $(cat "$out")"
  # Read by the sourced declared-wait test after this fixture returns.
  # shellcheck disable=SC2034
  MALFORMED_STATE=$state
}

assert_malformed_record_kept_the_ladder() {  # <state> <what>
  local state=$1 what=$2
  grep -F 'possible wedge, escalation 1' "$state/.wake-queue" >/dev/null \
    || fail "$what did not keep the unchanged ladder: $(cat "$state/.wake-queue" 2>/dev/null)"
  grep -F 'rechecked on a long cadence not a wedge' "$state/.wake-queue" >/dev/null \
    && fail "$what was deferred on a record that is not what it claims: $(cat "$state/.wake-queue")"
  [ "$(cat "$state/.wedge-escalations-test_fm-wedge" 2>/dev/null || echo 0)" -eq 1 ] \
    || fail "$what did not count its escalation"
}

hold_key() {
  printf '%s' test:fm-held-merge | tr ':/.' '___'
}

run_hold() {  # <dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_CONFIG_OVERRIDE="$dir/config" "$ROOT/bin/fm-captain-hold.sh" "$@" >/dev/null 2>&1
}

make_hold_home() {  # <name> <status-line> <hold|nohold>
  local name=$1 line=$2 hold=$3 dir state
  dir=$(make_case "$name"); state="$dir/state"
  mkdir -p "$dir/data" "$dir/config"
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml" || return 1
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  (cd "$dir" && tasks-axi add held-merge 'delivered work' --file data/backlog.md) >/dev/null 2>&1 \
    || return 1
  if [ "$hold" = hold ]; then
    run_hold "$dir" hold held-merge --reason 'awaiting the captain on the merge' || return 1
  fi
  printf 'window=test:fm-held-merge\nkind=ship\nharness=grok\nbackend=tmux\n' \
    > "$state/held-merge.meta"
  printf '%s\n' "$line" > "$state/held-merge.status"
  printf '%s' "$(seen_sig "$state/held-merge.status")" > "$state/.seen-held-merge_status"
  printf '%s\n' "$dir"
}

hold_watch_launch() {  # <dir> <out> <capture>
  local dir=$1 out=$2 capture=$3
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-held-merge \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS="${FM_HOLD_PAUSE_RESURFACE_SECS:-999}" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" 2>&1 &
  HOLD_WATCH_PID=$!
}

hold_watch_surface() {  # <dir> <out> <capture> <pane-text>
  local dir=$1 out=$2 capture=$3 text=$4
  printf '%s\n' "$text" > "$capture"
  hold_watch_launch "$dir" "$out" "$capture"
  wait_for_exit "$HOLD_WATCH_PID" 100 || { reap "$HOLD_WATCH_PID"; return 1; }
  return 0
}

hold_watch_churn() {  # <dir> <out> <capture> <label> <count>
  local dir=$1 out=$2 capture=$3 label=$4 count=$5 i=1 c
  local state="$dir/state"
  printf '%s 0\n' "$label" > "$capture"
  hold_watch_launch "$dir" "$out" "$capture"
  while [ "$i" -le "$count" ]; do
    printf '%s %s\n' "$label" "$i" > "$capture"
    c=0
    while [ "$c" -lt 3 ]; do
      wait_poll_cycle "$state" "$HOLD_WATCH_PID" 300 \
        || { reap "$HOLD_WATCH_PID"; return 1; }
      c=$((c + 1))
    done
    i=$((i + 1))
  done
  reap "$HOLD_WATCH_PID"
  return 0
}

hold_stale_wakes() {  # <state>
  awk -F '\t' '$3 == "stale" && $4 == "test:fm-held-merge" { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

iso_utc_at() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

write_away_record() {  # <state>
  if ! FM_HOME="$(dirname "$1")" FM_STATE_OVERRIDE="$1" "$ROOT/bin/fm-afk-contract.sh" enter >/dev/null 2>&1; then
    fail "could not write the away-posture record in $1"
  fi
}

archive_away_record() {  # <state>
  FM_HOME="$(dirname "$1")" FM_STATE_OVERRIDE="$1" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null 2>&1 \
    || fail "could not archive the away-posture record in $1"
}
