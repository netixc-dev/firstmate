#!/usr/bin/env bash
# Portable Pi extension regression for direct invocation of tracked owners.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-shell-invocation)

project="$TMP_ROOT/project"
fakebin="$TMP_ROOT/fakebin"
mkdir -p "$project/.pi/extensions/lib" "$project/bin" "$project/state" "$fakebin"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$project/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" \
  "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" "$project/.pi/extensions/lib/"

cat >"$fakebin/bash" <<'SH'
#!/bin/sh
printf 'unexpected bash wrapper: %s\n' "$*" >> "${FM_PI_SHELL_LOG:?}"
exit 97
SH
chmod +x "$fakebin/bash"

cat >"$project/bin/fm-sessionstart-run.sh" <<'SH'
#!/bin/bash
printf 'sessionstart:%s\n' "$*" >> "$FM_PI_SHELL_LOG"
SH
cat >"$project/bin/fm-cd-pretool-check.sh" <<'SH'
#!/bin/bash
printf 'cd:%s\n' "$*" >> "$FM_PI_SHELL_LOG"
SH
cat >"$project/bin/fm-arm-pretool-check.sh" <<'SH'
#!/bin/bash
printf 'arm:%s\n' "$*" >> "$FM_PI_SHELL_LOG"
SH
cat >"$project/bin/fm-turnend-guard.sh" <<'SH'
#!/bin/bash
cat >/dev/null
printf 'turnend:%s\n' "$*" >> "$FM_PI_SHELL_LOG"
SH
cat >"$project/bin/fm-operational-input.sh" <<'SH'
#!/bin/bash
printf 'operational:%s\n' "$*" >> "$FM_PI_SHELL_LOG"
input=$(cat)
if [ "$1" = encode ]; then
  printf 'encoded:%s:%s\n' "$2" "$input"
elif [ "$1" = classify ]; then
  printf 'classified:%s\n' "$input"
else
  printf 'not-operational\n'
fi
SH
chmod +x "$project/bin/"*.sh

log="$project/state/calls"
out=$(EXT="$project/.pi/extensions/fm-primary-turnend-guard.ts" \
  FM_HOME="$project" FM_ROOT_OVERRIDE="$project" FM_PI_SHELL_LOG="$log" \
  FM_OPERATIONAL_INPUT_SCRIPT="$project/bin/fm-operational-input.sh" \
  PATH="$fakebin:$PATH" \
  node --input-type=module 2>&1 <<'JS'
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  sendMessage() {},
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?portable=${Date.now()}`);
extension.default(pi);
const ctx = { sessionManager: { getSessionId: () => "portable-test" } };
handlers.get("session_start")({ reason: "startup" }, ctx);
await handlers.get("before_agent_start")({}, ctx);
await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "printf test" } });
await handlers.get("agent_settled")({}, ctx);
const operational = await import(`${new URL("./lib/fm-operational-input.ts", pathToFileURL(process.env.EXT)).href}?portable=${Date.now()}`);
const expectedScript = process.env.FM_OPERATIONAL_INPUT_SCRIPT;
const syncInvocation = operational.firstmateShellInvocation(expectedScript, ["classify"]);
if (
  syncInvocation.command !== expectedScript ||
  syncInvocation.args.join("\0") !== ["classify"].join("\0")
) {
  throw new Error(`unexpected sync invocation: ${JSON.stringify(syncInvocation)}`);
}
const classified = operational.classifyFirstmateOperationalText("probe");
if (classified !== "classified:probe") {
  throw new Error(`unexpected classified result: ${classified}`);
}
let asyncInvocation;
const encoded = await operational.encodeFirstmateOperationalInputWith(
  (command, args, { input }) => {
    asyncInvocation = { command, args: [...args], input };
    return new Promise((resolve, reject) => {
      const child = spawn(command, args, { stdio: ["pipe", "pipe", "ignore"] });
      let stdout = "";
      child.stdout.on("data", (chunk) => { stdout += chunk; });
      child.on("error", reject);
      child.on("close", (status) => resolve({ status, stdout }));
      child.stdin.end(input);
    });
  },
  "branch-outcome",
  "branch result",
);
if (encoded !== "encoded:branch-outcome:branch result\n") {
  throw new Error(`unexpected encoded branch outcome: ${encoded}`);
}
if (
  asyncInvocation.command !== expectedScript ||
  asyncInvocation.args.join("\0") !== ["encode", "branch-outcome"].join("\0") ||
  asyncInvocation.input !== "branch result"
) {
  throw new Error(`unexpected async invocation: ${JSON.stringify(asyncInvocation)}`);
}
const calls = readFileSync(process.env.FM_PI_SHELL_LOG, "utf8");
for (const expected of [
  "sessionstart:--source startup --pi-prerequisite",
  "cd:--command printf test",
  "arm:--command printf test",
  "turnend:",
  "operational:classify",
  "operational:encode branch-outcome",
]) {
  if (!calls.includes(expected)) throw new Error(`missing ${expected} in:\n${calls}`);
}
JS
)
status=$?
expect_code 0 "$status" "portable Pi shell seams"
[ -z "$out" ] || fail "portable Pi shell seam test printed output: $out"
[ ! -s "$log" ] || ! grep -Fq "unexpected bash wrapper" "$log" || fail "a tracked owner was invoked through the fake bash wrapper: $(cat "$log")"
pass "Pi session-start, pre-tool, turn-end, and operational-input seams invoke owners directly on supported hosts"
