#!/usr/bin/env bash
set -euo pipefail
ROOT=/Users/control/.no-mistakes/worktrees/874f0de57f61/01M3EBGDMVNX4HAMF7PS38E0SE
LAB="$ROOT/.live-grok-validation-$$"
LOG=/Users/control/.no-mistakes/evidence/01M3EBGDMVNX4HAMF7PS38E0SE/live-grok-removal-validation.log
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1
cleanup() {
  set +e
  for record in "$LAB"/*/tmux-dir; do
    [ -f "$record" ] || continue
    sock=$(cat "$record")
    TMUX_TMPDIR="$sock" tmux kill-server >/dev/null 2>&1 || true
    rm -rf "$sock"
  done
  rm -rf "$LAB"
}
trap cleanup EXIT
mkdir -p "$LAB"

say() { printf '\n=== %s ===\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
assert_file() { [ -f "$1" ] || fail "missing $1"; }
assert_absent() { [ ! -e "$1" ] || fail "unexpected $1"; }

new_case() { # name id harness pushed
  local name=$1 id=$2 harness=$3 pushed=$4 d
  d="$LAB/$name"
  local tmux_dir="/tmp/fmg$$-$name"
  mkdir -p "$d/home/state" "$d/home/data/$id" "$d/user" "$d/pool" "$tmux_dir"
  chmod 700 "$tmux_dir"
  printf '%s\n' "$tmux_dir" >"$d/tmux-dir"
  git init -q --bare "$d/origin.git"
  git -C "$d/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$d/origin.git" "$d/seed" 2>/dev/null
  git -C "$d/seed" -c user.name=live -c user.email=live@example.invalid commit -q --allow-empty -m baseline
  git -C "$d/seed" push -q origin main
  rm -rf "$d/seed"
  git clone -q "$d/origin.git" "$d/project"
  (cd "$d/project" && TREEHOUSE_ROOT="$d/pool" treehouse init >/dev/null)
  git -C "$d/project" add treehouse.toml
  git -C "$d/project" -c user.name=live -c user.email=live@example.invalid commit -q -m 'local treehouse config'
  git -C "$d/project" push -q origin main
  local wt
  wt=$(cd "$d/project" && TREEHOUSE_ROOT="$d/pool" treehouse get --lease --lease-holder "$id" 2>/dev/null)
  printf '%s\n' "$wt" >"$d/wt-path"
  git -C "$wt" checkout -q -b "fm/$id"
  printf 'product behavior for %s\n' "$id" >"$wt/result.txt"
  git -C "$wt" add result.txt
  git -C "$wt" -c user.name=live -c user.email=live@example.invalid commit -q -m "work for $id"
  if [ "$pushed" = yes ]; then git -C "$wt" push -q origin "fm/$id"; fi
  cat >"$d/home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Validate explicit migration to Pi in an isolated live product session.
## Firstmate spec
Remain running long enough for Firstmate to verify the replacement.
EOF
  cat >"$d/home/data/backlog.md" <<EOF
# Backlog

## In flight

## Queued

## Done
EOF
  tasks-axi add "$id" "live validation $id" --kind ship --file "$d/home/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$d/home/data/backlog.md" >/dev/null
  TMUX_TMPDIR="$tmux_dir" tmux new-session -d -s "live-$name" -n "fm-$id" -c "$wt"
  cat >"$d/home/state/$id.meta" <<EOF
window=live-$name:fm-$id
endpoint_task_id=$id
worktree=$wt
project=$d/project
harness=$harness
kind=ship
mode=local-only
spawn_gen=live-$id
model=default
effort=default
tasktmp=$d/tasktmp
EOF
  touch "$d/home/state/.last-watcher-beat"
  printf '%s\n' "$d"
}

run_env() { # case command...
  local d=$1; shift
  env -u NO_MISTAKES_GATE -u TMUX -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    FM_HOME="$d/home" HOME="$d/user" GROK_HOME="$d/user/.grok" \
    FM_GATE_REFUSE_BYPASS=1 TREEHOUSE_ROOT="$d/pool" TMUX_TMPDIR="$(cat "$d/tmux-dir")" \
    FM_CONTROL_POLL=0.05 FM_CONTROL_LAUNCH_WAIT=30 FM_CONTROL_EXIT_WAIT=10 \
    "$@"
}

seed_grok_wiring() { # case id
  local d=$1 id=$2 token="fm.222222222222" wt
  wt=$(cat "$d/wt-path")
  mkdir -p "$d/user/.grok/hooks/fm-turn-end.d"
  printf 'owned auth\n' >"$d/user/.grok/hooks/fm-turn-end.d/$token"
  printf '%s\n' "$token" >"$d/home/state/$id.grok-turnend-token"
  printf 'token=%s\n' "$token" >"$wt/.fm-grok-turnend"
  printf 'other task\n' >"$d/home/state/other.grok-turnend-token"
}

say 'Fresh standalone Grok selection refuses before task mutation'
d="$LAB/fresh-refusal"; mkdir -p "$d/home/state" "$d/home/data" "$d/home/config" "$d/user"
set +e
out=$(env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 FM_HOME="$d/home" HOME="$d/user" "$ROOT/bin/fm-spawn.sh" live-refuse "$ROOT" grok --mode local-only --yolo off 2>&1); rc=$?
set -e
printf '%s\n' "$out"
[ "$rc" -ne 0 ] || fail 'fresh Grok spawn unexpectedly succeeded'
printf '%s' "$out" | grep -q 'unsupported removed harness' || fail 'fresh Grok refusal was not explicit'
[ -z "$(find "$d/home/state" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail 'fresh Grok refusal mutated task state'
pass 'standalone Grok is rejected before task state exists'

say 'Legacy Grok record explicitly migrates to a real Pi process'
d=$(new_case migration migrate-grok grok-2 yes); seed_grok_wiring "$d" migrate-grok
printf 'neighbor auth\n' >"$d/user/.grok/hooks/fm-turn-end.d/fm.333333333333"
set +e
out=$(run_env "$d" "$ROOT/bin/fm-control.sh" migrate-grok relaunch --harness pi --note 'continue under supported Pi' 2>&1); rc=$?
set -e
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || fail "explicit Pi migration failed with rc=$rc"
grep -q '^harness=pi$' "$d/home/state/migrate-grok.meta" || fail 'replacement metadata is not Pi'
assert_absent "$d/home/state/migrate-grok.grok-turnend-token"
assert_absent "$(cat "$d/wt-path")/.fm-grok-turnend"
assert_absent "$d/user/.grok/hooks/fm-turn-end.d/fm.222222222222"
assert_file "$d/user/.grok/hooks/fm-turn-end.d/fm.333333333333"
assert_file "$d/home/state/other.grok-turnend-token"
cmd=$(TMUX_TMPDIR="$(cat "$d/tmux-dir")" tmux display-message -p -t live-migration:fm-migrate-grok '#{pane_current_command}')
printf 'replacement pane command: %s\n' "$cmd"
case "$cmd" in zsh|bash|sh) fail 'Pi replacement was not running' ;; esac
pass 'explicit agent-free migration launched Pi and retired only exact Grok wiring'
TMUX_TMPDIR="$(cat "$d/tmux-dir")" tmux kill-server
(cd "$d/project" && TREEHOUSE_ROOT="$d/pool" treehouse return --force "$(cat "$d/wt-path")" >/dev/null)

say 'Safely landed legacy Grok cleanup succeeds and exact wiring is removed'
d=$(new_case cleanup-landed cleanup-landed grok-2 yes); seed_grok_wiring "$d" cleanup-landed
out=$(run_env "$d" "$ROOT/bin/fm-teardown.sh" cleanup-landed 2>&1); rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || fail 'landed legacy Grok cleanup failed'
assert_absent "$d/home/state/cleanup-landed.meta"
assert_absent "$d/home/state/cleanup-landed.grok-turnend-token"
assert_absent "$d/user/.grok/hooks/fm-turn-end.d/fm.222222222222"
assert_file "$d/home/state/other.grok-turnend-token"
pass 'guarded cleanup accepted landed legacy work and removed only task-owned Grok wiring'

say 'Dirty and unlanded legacy Grok cleanup attempts are refused without loss'
for mode in dirty unlanded; do
  pushed=yes; [ "$mode" = unlanded ] && pushed=no
  d=$(new_case "cleanup-$mode" "cleanup-$mode" grok-2 "$pushed"); seed_grok_wiring "$d" "cleanup-$mode"
  wt=$(cat "$d/wt-path")
  [ "$mode" != dirty ] || printf 'unfinished\n' >"$wt/unfinished.txt"
  before=$(git -C "$wt" rev-parse HEAD)
  set +e
  out=$(run_env "$d" "$ROOT/bin/fm-teardown.sh" "cleanup-$mode" 2>&1); rc=$?
  set -e
  printf '%s\n' "$out"
  [ "$rc" -ne 0 ] || fail "$mode legacy cleanup unexpectedly succeeded"
  printf '%s' "$out" | grep -q 'REFUSED' || fail "$mode cleanup lacked refusal"
  assert_file "$d/home/state/cleanup-$mode.meta"
  assert_file "$d/home/state/cleanup-$mode.grok-turnend-token"
  assert_file "$d/user/.grok/hooks/fm-turn-end.d/fm.222222222222"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$before" ] || fail "$mode cleanup moved HEAD"
  [ "$mode" != dirty ] || grep -q unfinished "$wt/unfinished.txt" || fail 'dirty work was lost'
  pass "$mode legacy work remained intact after guarded refusal"
  TMUX_TMPDIR="$(cat "$d/tmux-dir")" tmux kill-server
  (cd "$d/project" && TREEHOUSE_ROOT="$d/pool" treehouse return --force "$wt" >/dev/null)
done

say 'Ordinary Pi task preserves Grok-named user files'
d=$(new_case ordinary-pi ordinary-pi pi yes); seed_grok_wiring "$d" ordinary-pi
wt=$(cat "$d/wt-path")
printf 'user-owned sentinel\n' >"$wt/.fm-grok-turnend"
set +e
out=$(run_env "$d" "$ROOT/bin/fm-teardown.sh" ordinary-pi 2>&1); rc=$?
set -e
printf '%s\n' "$out"
[ "$rc" -ne 0 ] || fail 'ordinary Pi teardown deleted an untracked Grok-named file'
printf '%s' "$out" | grep -q 'REFUSED' || fail 'ordinary Pi file did not trigger safety refusal'
grep -q 'user-owned sentinel' "$wt/.fm-grok-turnend" || fail 'ordinary Pi worktree sentinel changed'
assert_file "$d/home/state/ordinary-pi.grok-turnend-token"
assert_file "$d/user/.grok/hooks/fm-turn-end.d/fm.222222222222"
assert_file "$d/home/state/ordinary-pi.meta"
pass 'ordinary Pi Grok-named worktree, state, and auth files were preserved'
TMUX_TMPDIR="$(cat "$d/tmux-dir")" tmux kill-server
(cd "$d/project" && TREEHOUSE_ROOT="$d/pool" treehouse return --force "$wt" >/dev/null)

say 'Legacy Grok diagnostic distinguishes migration from guarded cleanup'
d=$(new_case diagnostic diagnose-grok grok-helper yes)
out=$(run_env "$d" "$ROOT/bin/fm-crew-state.sh" diagnose-grok 2>&1); rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || fail 'legacy diagnostic command failed'
printf '%s' "$out" | grep -q 'explicit supported-harness replacement' || fail 'diagnostic omitted migration guidance'
printf '%s' "$out" | grep -q 'guarded teardown for safely landed work' || fail 'diagnostic omitted cleanup guidance'
assert_file "$d/home/state/diagnose-grok.meta"
pass 'operator diagnostic advertises explicit replacement and guarded landed cleanup without mutation'
TMUX_TMPDIR="$(cat "$d/tmux-dir")" tmux kill-server
(cd "$d/project" && TREEHOUSE_ROOT="$d/pool" treehouse return --force "$(cat "$d/wt-path")" >/dev/null)

say 'All live product scenarios passed'
