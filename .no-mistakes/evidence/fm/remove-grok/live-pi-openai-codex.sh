#!/usr/bin/env bash
set -euo pipefail
ROOT=/Users/control/.no-mistakes/worktrees/874f0de57f61/01M3EBGDMVNX4HAMF7PS38E0SE
LAB="$ROOT/bin/fm-herdr-lab.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-remove-grok-live.XXXXXX")
SESSION=$($LAB name remove-grok-live)
WT=
PANE=
cleanup() {
  rc=$?
  set +e
  if [ -n "$PANE" ]; then "$LAB" run "$SESSION" pane close "$PANE" >/dev/null 2>&1; fi
  if [ -n "$WT" ]; then treehouse return --force "$WT" >/dev/null 2>&1; fi
  "$LAB" teardown "$SESSION" >/dev/null 2>&1
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

# Do not inherit a launcher identity from the operator's session.
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
export HERDR_SESSION="$SESSION"
"$LAB" provision "$SESSION"

HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$PROJECT"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
git -C "$PROJECT" init -q
printf '# live Pi preservation scenario\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJECT" "$TMP_ROOT/project.origin.git"
git -C "$PROJECT" remote add origin "file://$TMP_ROOT/project.origin.git"

# The scaffold explicitly carries the Herdr-lab lifecycle contract.
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" live-pi project --scout --herdr-lab >/dev/null
BRIEF="$HOME_DIR/data/live-pi/brief.md"
python3 - "$BRIEF" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
s=s.replace('{TASK}', 'Preserve plain Pi worker behavior while standalone Grok support is removed.')
s=s.replace('{FIRSTMATE_SPEC}', 'Launch Pi with an openai-codex model in the isolated Herdr lab, then remain idle.')
p.write_text(s)
PY

FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" live-pi "$PROJECT" --scout --harness pi \
  --model openai-codex/gpt-5.6-sol --effort high --backend herdr
META="$HOME_DIR/state/live-pi.meta"
WT=$(awk -F= '$1=="worktree" {print substr($0,index($0,"=")+1)}' "$META")
PANE=$(awk -F= '$1=="herdr_pane_id" {print $2}' "$META")

status=
for _ in $(seq 1 60); do
  status=$("$LAB" run "$SESSION" agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty' || true)
  case "$status" in idle|done|blocked|working) break ;; esac
  sleep 1
done
agent=$("$LAB" run "$SESSION" agent get "$PANE")
process=$("$LAB" run "$SESSION" pane process-info --pane "$PANE")

printf 'session=%s\n' "$SESSION"
printf 'spawned harness=%s model=%s effort=%s backend=%s\n' \
  "$(awk -F= '$1=="harness" {print $2}' "$META")" \
  "$(awk -F= '$1=="model" {print $2}' "$META")" \
  "$(awk -F= '$1=="effort" {print $2}' "$META")" \
  "$(awk -F= '$1=="backend" {print $2}' "$META")"
printf 'native_agent=%s native_status=%s\n' \
  "$(printf '%s' "$agent" | jq -r '.result.agent.agent')" \
  "$(printf '%s' "$agent" | jq -r '.result.agent.agent_status')"
printf 'foreground_processes=%s\n' "$(printf '%s' "$process" | jq -c '[.result.process_info.foreground_processes[]? | {name,argv0,argv}]')"
printf 'legacy_grok_token=%s legacy_grok_pointer=%s\n' \
  "$(test -e "$HOME_DIR/state/live-pi.grok-turnend-token" && echo present || echo absent)" \
  "$(test -e "$WT/.fm-grok-turnend" && echo present || echo absent)"

[ "$(awk -F= '$1=="harness" {print $2}' "$META")" = pi ]
[ "$(awk -F= '$1=="model" {print $2}' "$META")" = openai-codex/gpt-5.6-sol ]
[ "$(printf '%s' "$agent" | jq -r '.result.agent.agent')" = pi ]
[ ! -e "$HOME_DIR/state/live-pi.grok-turnend-token" ]
[ ! -e "$WT/.fm-grok-turnend" ]
