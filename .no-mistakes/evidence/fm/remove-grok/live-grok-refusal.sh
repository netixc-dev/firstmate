#!/usr/bin/env bash
set -euo pipefail
ROOT=/Users/control/.no-mistakes/worktrees/874f0de57f61/01M3EBGDMVNX4HAMF7PS38E0SE
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-remove-grok-refusal.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$PROJECT"
git -C "$PROJECT" init -q
printf '# Grok refusal scenario\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" reject-grok project --scout >/dev/null
BRIEF="$HOME_DIR/data/reject-grok/brief.md"
python3 - "$BRIEF" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text().replace('{TASK}', 'Confirm standalone Grok workers cannot launch.')
s=s.replace('{FIRSTMATE_SPEC}', 'Attempt the removed adapter through public spawn inputs and preserve task state.')
p.write_text(s)
PY
run_case() {
  label=$1; shift
  set +e
  out=$(FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" reject-grok "$PROJECT" --scout "$@" 2>&1)
  rc=$?
  set -e
  printf '%s rc=%s output=%s\n' "$label" "$rc" "$out"
  [ "$rc" -ne 0 ]
  case "$out" in *'unsupported removed'*) ;; *) return 1 ;; esac
  [ ! -e "$HOME_DIR/state/reject-grok.meta" ]
  [ ! -e "$HOME_DIR/state/reject-grok.busy-state" ]
}
run_case typed --harness grok
run_case prefixed --harness grok-2
run_case raw 'env -u CLAUDECODE /usr/bin/grok --always-approve'
printf 'durable_task_metadata=absent busy_state=absent\n'
