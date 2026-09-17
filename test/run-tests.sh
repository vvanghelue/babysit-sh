#!/usr/bin/env bash
# Integration tests for babysit.sh.
#
#   ./test/run-tests.sh
#
# Everything runs in temp dirs with stub "worker sessions" -- small shell
# scripts that read the state, change it, and exit the way an agent would.
# No agent CLI, no model, no network. Exits non-zero if anything fails.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BABYSIT="$DIR/babysit.sh"
WORK="$(mktemp -d)"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; fi; }
cval() { awk -F= -v k="$1" '$1 == k { print $2 }' "$2/.babysit/counters"; }
has()  { if grep -q -- "$2" <<<"$3"; then ok "$1"; else bad "$1  (missing: $2)"; fi; }

cleanup() {
  pkill -f "$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# Deterministic: force a harness and never let a real CLI near the tests.
export BABYSIT_HARNESS=pi
export BABYSIT_SLEEP=0
export BABYSIT_KILL_GRACE=3
unset PI_SESSION_FILE PI_SESSION_ID BABYSIT_CMD BABYSIT_DIR 2>/dev/null || true

newproj() { # newproj <name> -> path, initialized
  local p="$WORK/$1"
  mkdir -p "$p"
  "$BABYSIT" init --task "test task for $1" --dir "$p/.babysit" >/dev/null 2>&1
  printf '%s' "$p"
}

# ---------------------------------------------------------------- stubs -----
cat >"$WORK/stub-progress.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
D="\${BABYSIT_DIR:?}"
n="\$(awk -F= '\$1=="sessions_run"{print \$2}' "\$D/counters")"
echo "stub: session \$n pid \$\$ deadline=\${BABYSIT_DEADLINE:-none} timeout=\${BABYSIT_SESSION_TIMEOUT:-none}"
"$BABYSIT" budget
printf '# State\\n\\n- session: %s\\n- status: working\\n\\n## Done\\n\\n- step %s\\n\\n## Next steps\\n\\n1. step %s\\n' "\$n" "\$n" "\$((n + 1))" > "\$D/STATE.md"
printf 'session %s did step %s\\n' "\$n" "\$n" >> "\$D/WORKLOG.md"
if [ "\$n" -ge 3 ]; then "$BABYSIT" done --note "three steps done" >/dev/null; fi
EOF

cat >"$WORK/stub-lazy.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub: did some work but wrote no state"
EOF

cat >"$WORK/stub-fail.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub: failing on purpose"
exit 3
EOF

cat >"$WORK/stub-hang.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub: hanging forever"
sleep 300
EOF

cat >"$WORK/stub-stop.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
D="\${BABYSIT_DIR:?}"
n="\$(awk -F= '\$1=="sessions_run"{print \$2}' "\$D/counters")"
printf '# State\\n\\n- session: %s\\n' "\$n" > "\$D/STATE.md"
if [ "\$n" -ge 2 ]; then "$BABYSIT" stop >/dev/null; echo "stub: asked the supervisor to stop"; fi
EOF
cat >"$WORK/stub-slow.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
D="\${BABYSIT_DIR:?}"
n="\$(awk -F= '\$1=="sessions_run"{print \$2}' "\$D/counters")"
printf '# State\\n\\n- session: %s\\n' "\$n" > "\$D/STATE.md"
sleep 3
EOF
chmod +x "$WORK"/stub-*.sh

printf '\n== 1. detect and init ==\n'
out="$("$BABYSIT" detect)"
has "detect reports the forced harness" "harness=pi" "$out"
has "detect reports a state dir" "dir=" "$out"
P="$(newproj initproj)"
for f in TASK.md STATE.md WORKLOG.md counters; do
  [ -f "$P/.babysit/$f" ] && ok "created $f" || bad "missing $f"
done
has "goal recorded in TASK.md" "test task for initproj" "$(cat "$P/.babysit/TASK.md")"
has "counters start at zero" "sessions_run=0" "$(cat "$P/.babysit/counters")"

printf '\n== 2. budget: the time-based decision a worker reads ==\n'
out="$(BABYSIT_DIR="$P/.babysit" BABYSIT_SESSION=4 BABYSIT_DEADLINE=$(( $(date +%s) + 3000 )) \
       BABYSIT_SESSION_TIMEOUT=3600 BABYSIT_MAX_SESSIONS=100 "$BABYSIT" budget)"
has "budget prints the session number" "SESSION=4" "$out"
has "budget prints the remaining time" "REMAINING=" "$out"
has "plenty of time means continue" "DECISION=continue" "$out"
out="$(BABYSIT_DIR="$P/.babysit" BABYSIT_SESSION=4 BABYSIT_DEADLINE=$(( $(date +%s) + 30 )) \
       BABYSIT_SESSION_TIMEOUT=3600 "$BABYSIT" budget)"
has "almost out of time means handoff-now" "DECISION=handoff-now" "$out"

printf '\n== 3. once: exactly one session, foreground ==\n'
P="$(newproj onceproj)"
out="$(BABYSIT_CMD="bash $WORK/stub-progress.sh" "$BABYSIT" once --dir "$P/.babysit" 2>&1)"; rc=$?
check "once exits 0" "0" "$rc"
has "once reports the session" "session 1 finished" "$out"
log="$(cat "$P/.babysit/current.log")"
has "the worker saw its session number" "session 1 pid" "$(cat "$log")"
has "the worker got a real deadline" "timeout=3600" "$(cat "$log")"
has "the worker can read its budget" "DECISION=" "$(cat "$log")"
check "one session counted" "1" "$(cval sessions_run "$P")"
[ -n "$(ls "$P/.babysit/sessions/"session-*.log 2>/dev/null)" ] && ok "session log written" || bad "no session log"
has "state was updated by the worker" "step 1" "$(cat "$P/.babysit/STATE.md")"

printf '\n== 4. run: sessions until the worker marks the task done ==\n'
P="$(newproj runproj)"
out="$(BABYSIT_CMD="bash $WORK/stub-progress.sh" timeout 90 "$BABYSIT" run --dir "$P/.babysit" \
       --max-sessions 10 --session-timeout 20 2>&1)"; rc=$?
check "run exits 0 when the goal is reached" "0" "$rc"
check "exactly three sessions ran" "3" "$(cval sessions_run "$P")"
[ -f "$P/.babysit/DONE" ] && ok "done marker written" || bad "no done marker"
has "supervisor says why it stopped" "goal reached" "$out"
has "no failures were recorded" "failures=0" "$("$BABYSIT" status --dir "$P/.babysit")"
out="$(BABYSIT_CMD="bash $WORK/stub-progress.sh" "$BABYSIT" run --dir "$P/.babysit" 2>&1)"
has "a done task is not restarted" "already done" "$out"

printf '\n== 5. session budget is enforced ==\n'
P="$(newproj budgetproj)"
BABYSIT_CMD="bash $WORK/stub-progress.sh" timeout 60 "$BABYSIT" run --dir "$P/.babysit" \
  --max-sessions 2 --session-timeout 20 >/dev/null 2>&1
check "budget capped the run" "2" "$(cval sessions_run "$P")"
has "halt reason is recorded" "budget exhausted" "$(cat "$P/.babysit/HALTED")"
has "status shows it halted" "halted:" "$("$BABYSIT" status --dir "$P/.babysit")"

printf '\n== 6. a session that changes nothing is a stalled session ==\n'
P="$(newproj stallproj)"
out="$(BABYSIT_CMD="bash $WORK/stub-lazy.sh" timeout 60 "$BABYSIT" run --dir "$P/.babysit" \
       --max-sessions 10 --stall-limit 2 --session-timeout 20 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "stalling run exits non-zero" || bad "stalling run exited 0"
has "stall is named as the reason" "no progress" "$(cat "$P/.babysit/HALTED")"
has "the log says the state did not change" "STATE.md unchanged" "$(cat "$P/.babysit/supervisor.log")"
check "it stopped after the stall limit" "2" "$(cval sessions_run "$P")"

printf '\n== 7. repeated failures halt loudly ==\n'
P="$(newproj failproj)"
out="$(BABYSIT_CMD="bash $WORK/stub-fail.sh" timeout 60 "$BABYSIT" run --dir "$P/.babysit" \
       --max-sessions 10 --max-failures 2 --session-timeout 20 2>&1)"
has "failures are named as the reason" "consecutive session failures" "$(cat "$P/.babysit/HALTED")"
check "it stopped after two failures" "2" "$(cval sessions_run "$P")"
check "failure count is recorded" "2" "$(cval consecutive_failures "$P")"

printf '\n== 8. a session that overruns its timeout is killed ==\n'
P="$(newproj timeoutproj)"
out="$(BABYSIT_CMD="bash $WORK/stub-hang.sh" timeout 60 "$BABYSIT" run --dir "$P/.babysit" \
       --max-sessions 10 --max-failures 1 --session-timeout 3 2>&1)"
has "the timeout is logged" "session timeout" "$(cat "$P/.babysit/supervisor.log")"
has "the timeout counts as a failure" "consecutive session failures" "$(cat "$P/.babysit/HALTED")"
if pgrep -f "$WORK/stub-hang.sh" >/dev/null 2>&1; then bad "hung session was left running"; else ok "hung session was killed"; fi

printf '\n== 9. stop file ends the run between sessions ==\n'
P="$(newproj stopproj)"
out="$(BABYSIT_CMD="bash $WORK/stub-stop.sh" timeout 60 "$BABYSIT" run --dir "$P/.babysit" \
       --max-sessions 10 --session-timeout 20 2>&1)"; rc=$?
check "a stopped run exits 0" "0" "$rc"
has "the reason is 'stopped by user'" "stopped by user" "$out"
check "two sessions ran before the stop" "2" "$(cval sessions_run "$P")"
"$BABYSIT" resume --dir "$P/.babysit" >/dev/null
[ -f "$P/.babysit/stop" ] && bad "resume did not remove the stop file" || ok "resume re-arms the run"

printf '\n== 10. start: the supervisor itself is a detached long-running process ==\n'
P="$(newproj startproj)"
BABYSIT_CMD="bash $WORK/stub-slow.sh" timeout 30 "$BABYSIT" start --dir "$P/.babysit" \
  --max-sessions 50 --session-timeout 30 >/dev/null 2>&1
sout="$("$BABYSIT" status --dir "$P/.babysit")"
has "status reports a running supervisor" "supervisor: RUNNING" "$sout"
# The supervisor is between sessions for a moment, so poll until a session is up.
for _ in $(seq 1 10); do
  sout="$("$BABYSIT" status --dir "$P/.babysit")"
  grep -q "session:    RUNNING" <<<"$sout" && break
  sleep 1
done
has "status reports a running session" "session:    RUNNING" "$sout"
check "the supervisor outlived the command that started it" "yes" "$(pgrep -f "$P/.babysit" >/dev/null 2>&1 && echo yes || echo no)"
"$BABYSIT" stop --kill --dir "$P/.babysit" >/dev/null 2>&1
for _ in $(seq 1 15); do sleep 1; pgrep -f "$P/.babysit" >/dev/null 2>&1 || break; done
has "stop --kill actually stops it" "supervisor: not running" "$("$BABYSIT" status --dir "$P/.babysit")"

printf '\n== 11. the worker prompt carries the contract and the task ==\n'
P="$(newproj promptproj)"
out="$("$BABYSIT" print --dir "$P/.babysit" 2>&1)"
has "prompt names the task" "test task for promptproj" "$out"
has "prompt forbids spawning sessions" "Do NOT launch another agent session" "$out"
has "prompt tells the worker how to finish" "done --note" "$out"
has "prompt points at the state files" "$P/.babysit/STATE.md" "$out"

printf '\n== 12. done, halt and reset ==\n'
P="$(newproj cmdproj)"
"$BABYSIT" 'done' --note "because the tests say so" --dir "$P/.babysit" >/dev/null
has "done records the note" "because the tests say so" "$(cat "$P/.babysit/DONE")"
"$BABYSIT" reset --yes --dir "$P/.babysit" >/dev/null
[ -f "$P/.babysit/DONE" ] && bad "reset kept the done marker" || ok "reset cleared runtime state"
[ -f "$P/.babysit/TASK.md" ] && ok "reset kept TASK.md" || bad "reset deleted TASK.md"
"$BABYSIT" halt --reason "worker found a blocker" --dir "$P/.babysit" >/dev/null
has "halt records a reason" "worker found a blocker" "$(cat "$P/.babysit/HALTED")"

printf '\n== 13. the piped installer downloads a working driver ==\n'
# Same code path as `curl ... | bash`: BASH_SOURCE is empty when bash reads the
# script from stdin, so install.sh must fall back to downloading. The raw base
# points at this checkout via file:// instead of the network.
PIPE_PROJ="$WORK/piped"; mkdir -p "$PIPE_PROJ"
out="$(BABYSIT_RAW_BASE="file://$DIR" bash -s -- "$PIPE_PROJ" < "$DIR/install.sh" 2>&1)"; rc=$?
check "piped install exits 0" "0" "$rc"
if diff -q "$PIPE_PROJ/.babysit/babysit.sh" "$DIR/babysit.sh" >/dev/null 2>&1; then
  ok "downloaded driver is byte-identical"
else
  bad "downloaded driver differs from babysit.sh: $out"
fi
[ -x "$PIPE_PROJ/.babysit/babysit.sh" ] && ok "driver installed and executable" || bad "driver not executable"
[ -f "$PIPE_PROJ/.babysit/TASK.md" ] && ok "init ran during the piped install" || bad "init did not run"
[ -f "$PIPE_PROJ/.babysit/ENTRYPOINT.md" ] && ok "entry-point prompt installed" || bad "entry-point prompt missing"
has "installer reports the source ref" "@" "$out"
BAD_PROJ="$WORK/badref"; mkdir -p "$BAD_PROJ"
if BABYSIT_RAW_BASE="file://$DIR/no-such-ref" bash -s -- "$BAD_PROJ" < "$DIR/install.sh" >/dev/null 2>&1; then
  bad "bad ref is rejected"
else
  ok "bad ref is rejected"
fi

printf '\n== results ==\n'
printf 'passed: %s\nfailed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'all good\n'