#!/usr/bin/env bash
# =============================================================================
# babysit.sh — agent-agnostic supervisor for long-running agent tasks.
#
# Where agent-loop hands the baton from session to session (the agent launches
# its own successor), babysit does the opposite: an EXTERNAL supervisor process
# owns the long-running task and starts fresh worker sessions one after another
# until the task is done, the budget runs out, or a human stops it.
#
# That means a worker session cannot break the chain. If it crashes, times out,
# spins, exits without writing state, or never even starts, the supervisor sees
# it and acts: retry, escalate, or halt loudly.
#
#   babysit.sh detect                  which harness am I inside?
#   babysit.sh init [--task T]         create .babysit/ (TASK.md, STATE.md, ...)
#   babysit.sh run [options]           supervise sessions in the foreground
#   babysit.sh start [options]         same as run --detach: survives your shell
#   babysit.sh once                    run exactly one session (foreground)
#   babysit.sh budget                  session time budget + decision (workers)
#   babysit.sh print                   prompt the next session will receive
#   babysit.sh status                  supervisor alive? progress? last log
#   babysit.sh logs [N]                tail the supervisor log
#   babysit.sh tail                    tail the current session log
#   babysit.sh done [--note T]         mark the task complete
#   babysit.sh halt --reason R         stop the supervisor with a reason
#   babysit.sh stop [--kill]           stop after this session / right now
#   babysit.sh resume                  clear stop/halted, keep the state
#   babysit.sh reset --yes             wipe runtime state, keep TASK.md
#
# run options (env var in brackets, all optional):
#   --max-sessions N       [BABYSIT_MAX_SESSIONS=100]    session budget
#   --session-timeout S    [BABYSIT_SESSION_TIMEOUT=3600] kill a session that runs long
#   --max-failures N       [BABYSIT_MAX_FAILURES=5]      consecutive failures -> halt
#   --stall-limit N        [BABYSIT_STALL_LIMIT=3]       sessions with no STATE.md change -> halt
#   --sleep S              [BABYSIT_SLEEP=5]             pause between sessions
#   --until CMD            [BABYSIT_UNTIL]               CMD succeeds -> done
#   --harness H            [BABYSIT_HARNESS]             pi|opencode|codex|claude
#   --model M              [BABYSIT_MODEL]               model for worker sessions
#   --provider P           [BABYSIT_PROVIDER]            provider (pi only)
#   --dir D                [BABYSIT_DIR=.babysit]        state directory
#   --detach / --foreground
#
# Harness override for anything else:
#   BABYSIT_CMD='mytool run --prompt-file @@PROMPT_FILE@@'
#
# The supervisor is just a process: run it under systemd, tmux, nohup or
# `babysit.sh start`. Every task has its own BABYSIT_DIR, so several long tasks
# can run side by side without knowing about each other.
# =============================================================================
set -uo pipefail

SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in
  */*) SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)" ;;
  *)   SCRIPT_DIR="$(pwd)" ;;
esac
ABS_SELF="$SCRIPT_DIR/$(basename "$SCRIPT_PATH")"

PROJECT="${BABYSIT_PROJECT:-$(pwd)}"
DIR="${BABYSIT_DIR:-$PROJECT/.babysit}"

# All paths derive from DIR, and --dir can change DIR, so keep them in one place.
set_paths() {
  TASK_FILE="$DIR/TASK.md"
  STATE_FILE="$DIR/STATE.md"
  WORKLOG_FILE="$DIR/WORKLOG.md"
  PROMPT_FILE="$DIR/prompt.next.md"
  SESS_DIR="$DIR/sessions"
  SUP_PID="$DIR/supervisor.pid"
  SESS_PID="$DIR/session.pid"
  HEARTBEAT="$DIR/heartbeat"
  DEADLINE_FILE="$DIR/session.deadline"
  STOP_FILE="$DIR/stop"
  DONE_FILE="$DIR/DONE"
  HALTED_FILE="$DIR/HALTED"
  SUP_LOG="$DIR/supervisor.log"
  COUNTERS="$DIR/counters"
  STATE_HASH_FILE="$DIR/state.hash"
  CURRENT_LOG_FILE="$DIR/current.log"
}
set_paths

# --dir may appear anywhere on the command line; pull it out before dispatch so
# every subcommand honours it, not just `run`.
_pre=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:?--dir needs a value}"; shift 2 ;;
    *) _pre+=("$1"); shift ;;
  esac
done
set -- "${_pre[@]+${_pre[@]}}"
export BABYSIT_DIR="$DIR"
set_paths

MAX_SESSIONS="${BABYSIT_MAX_SESSIONS:-100}"
SESSION_TIMEOUT="${BABYSIT_SESSION_TIMEOUT:-3600}"
MAX_FAILURES="${BABYSIT_MAX_FAILURES:-5}"
STALL_LIMIT="${BABYSIT_STALL_LIMIT:-3}"
SLEEP_BETWEEN="${BABYSIT_SLEEP:-5}"
UNTIL_CMD="${BABYSIT_UNTIL:-}"
KILL_GRACE="${BABYSIT_KILL_GRACE:-10}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
now() { date +%s; }
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
logline() { mkdir -p "$DIR"; printf '[%s] %s\n' "$(stamp)" "$*" >>"$SUP_LOG"; }
is_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# ------------------------------------------------------------------ counters --
counter() { # counter <name> -> value
  [ -f "$COUNTERS" ] || { printf '0'; return; }
  awk -F= -v k="$1" '$1 == k { v = $2 } END { print (v == "" ? 0 : v) }' "$COUNTERS"
}
set_counter() { # set_counter <name> <value>
  mkdir -p "$DIR"
  local tmp; tmp="$DIR/.counters.tmp"
  if [ -f "$COUNTERS" ]; then grep -v "^$1=" "$COUNTERS" >"$tmp" 2>/dev/null || true; fi
  printf '%s=%s\n' "$1" "$2" >>"$tmp"
  mv "$tmp" "$COUNTERS"
}

# -------------------------------------------------------------------- detect --
ancestors() {
  local pid=$$ i=0
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ] && [ "$i" -lt 12 ]; do
    ps -o args= -p "$pid" 2>/dev/null
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    i=$((i + 1))
  done
}

detect_harness() {
  if [ -n "${BABYSIT_HARNESS:-}" ]; then printf '%s' "$BABYSIT_HARNESS"; return; fi
  if [ -n "${AGENT_LOOP_HARNESS:-}" ]; then printf '%s' "$AGENT_LOOP_HARNESS"; return; fi
  # The harness we were launched by (the supervisor inherits nothing useful,
  # but a worker session does -- and that is how the chain stays on one CLI).
  if [ -n "${BABYSIT_HARNESS_PARENT:-}" ]; then printf '%s' "$BABYSIT_HARNESS_PARENT"; return; fi
  if [ -n "${PI_SESSION_FILE:-}" ] || [ -n "${PI_SESSION_ID:-}" ]; then printf 'pi'; return; fi
  if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CODEX_SANDBOX:-}" ]; then printf 'codex'; return; fi
  if [ -n "${CLAUDECODE:-}" ] || [ -n "${CLAUDE_SESSION_ID:-}" ]; then printf 'claude'; return; fi
  if [ -n "${OPENCODE_CLIENT:-}" ] || [ -n "${OPENCODE_CONFIG_DIR:-}" ]; then printf 'opencode'; return; fi
  local tree; tree="$(ancestors)"
  if printf '%s' "$tree" | grep -qiE '(^|[ /])opencode([ /]|$)'; then printf 'opencode'; return; fi
  if printf '%s' "$tree" | grep -qiE '(^|[ /])codex([ /]|$)';   then printf 'codex';    return; fi
  if printf '%s' "$tree" | grep -qiE 'claude';                   then printf 'claude';   return; fi
  if printf '%s' "$tree" | grep -qE 'bin/pi( |$)|/pi-cli|pi-coding-agent'; then printf 'pi'; return; fi
  local found=() c
  for c in pi opencode codex claude; do command -v "$c" >/dev/null 2>&1 && found+=("$c"); done
  if [ "${#found[@]}" -eq 1 ]; then printf '%s' "${found[0]}"; return; fi
  printf 'unknown'
}

# ---------------------------------------------------------------- launching --
adapter_cmd() { # sets CMD[@]; prompt text is $1, prompt file is $PROMPT_FILE
  local prompt="$1" h model provider
  h="$(detect_harness)"
  model="${BABYSIT_MODEL:-}"
  provider="${BABYSIT_PROVIDER:-${PI_PROVIDER:-}}"
  [ -n "$model" ] || model="${PI_MODEL:-}"

  if [ -n "${BABYSIT_CMD:-}" ]; then
    # @@PROMPT_FILE@@ is the reliable substitution (paths survive spaces and
    # newlines); @@PROMPT@@ inlines the text and splits on whitespace.
    local tpl="${BABYSIT_CMD//@@PROMPT_FILE@@/$PROMPT_FILE}"
    tpl="${tpl//@@PROMPT@@/$prompt}"
    # shellcheck disable=SC2206
    CMD=( $tpl )
    return
  fi

  case "$h" in
    pi)
      CMD=(pi --approve -p "$prompt")
      [ -n "$provider" ] && CMD+=(--provider "$provider")
      [ -n "$model" ]    && CMD+=(--model "$model") ;;
    opencode)
      CMD=(opencode run --auto --dir "$PROJECT" "$prompt")
      [ -n "$model" ] && CMD+=(--model "$model") ;;
    codex)
      CMD=(codex exec --sandbox workspace-write --skip-git-repo-check -C "$PROJECT" "$prompt") ;;
    claude)
      CMD=(claude -p "$prompt" --permission-mode bypassPermissions --add-dir "$PROJECT") ;;
    *)
      die "unknown harness: use --harness pi|opencode|codex|claude, or BABYSIT_CMD" ;;
  esac
}

# ------------------------------------------------------------------- prompt --
build_contract() {
  cat <<'CONTRACT'
# You are one worker session in a supervised long-running task

An external supervisor started you. It will start a fresh session when you
exit, and it will keep doing that until the task is done, the budget runs out,
or a human stops it. You do not manage the loop -- you do one bounded unit of
work and leave the state clean.

    DIR=@@DIR@@
    SELF=@@SELF@@

## Non-negotiable rules

1. Read the state before touching anything:

       @@DIR@@/TASK.md      the goal and its definition of done (stable)
       @@DIR@@/STATE.md     done / in progress / next / blockers (live)
       @@DIR@@/WORKLOG.md   what previous sessions changed and learned

   Never redo finished work, and never trust this prompt for status.

2. Check your budget at the start of the session, and again before you open a
   new piece of work:

       @@SELF@@ budget

   `DECISION=continue` means keep going. `wrap-up-soon` means close the current
   step and write your state. `handoff-now` means finish the atomic thing in
   your hands, update the state files and EXIT. Do not start new work on
   `handoff-now` -- the supervisor is about to kill you and a killed session
   that has not written state loses everything it did.

3. Leave the workspace in a state that works. A half-applied edit, a failing
   build or a deleted file that the next session needs is worse than doing less.

4. Before you exit, ALWAYS:

       rewrite @@DIR@@/STATE.md   for a reader who has never seen this session
       append one entry to @@DIR@@/WORKLOG.md   session number, what changed,
                                                what you learned, what is next

   These files are the only memory between sessions. Anything not written there
   is lost when you exit.

5. If the goal in TASK.md is fully achieved:

       @@SELF@@ done --note "what proves it"

   That tells the supervisor to stop launching sessions. Then exit.

6. If you are blocked and cannot make progress after genuinely trying:

       @@SELF@@ halt --reason "what is blocking and what was tried"

   The supervisor stops and tells the human. Do not spin, do not retry the same
   failing thing forever, and do not exit silently with the task unfinished.

7. Do NOT launch another agent session, do not wait for one, and do not sleep
   to keep yourself alive. Succession is the supervisor's job. Exiting is
   normal and expected -- it is how the next session starts.

8. Do not delete @@DIR@@, do not truncate WORKLOG.md, do not remove the
   supervisor's files.

## Reply format

First line of every user-facing reply:

    SESSION=<n> REMAINING=<seconds> DECISION=<continue|wrap-up-soon|handoff-now>

Then, briefly: what you did this session, and what the next session should do
first. Keep it short. Nobody is watching interactively; the logs are.
CONTRACT
}

build_prompt() {
  build_contract | sed -e "s#@@SELF@@#$ABS_SELF#g" -e "s#@@DIR@@#$DIR#g"
  if [ -f "$TASK_FILE" ]; then
    printf '\n---\n\n# Task\n\n'
    cat "$TASK_FILE"
  else
    printf '\n---\n\n# Task\n\n(no %s yet -- create it)\n' "$TASK_FILE"
  fi
  if [ -f "$DIR/addendum.md" ]; then
    printf '\n---\n\n# Addendum for the next session\n\n'
    cat "$DIR/addendum.md"
  fi
}

# --------------------------------------------------------------------- init --
cmd_init() {
  local task=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task|--goal) task="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  mkdir -p "$DIR" "$SESS_DIR"
  [ -f "$COUNTERS" ] || {
    printf 'sessions_run=0\nconsecutive_failures=0\nstall_count=0\n' >"$COUNTERS"
  }
  if [ ! -f "$TASK_FILE" ]; then
    cat >"$TASK_FILE" <<EOF
# Long-running task

${task:-<describe the end state in one or two sentences>}

## Definition of done

- <observable, testable condition, e.g. "the migration job reports 0 failures">

## Constraints

- <what must not happen; what is expensive; what to skip>
- <secrets, hosts or paths the task must not touch>

## Notes for workers

- Keep the workspace working at the end of every session.
- Prefer a small, verified step over a large speculative one.
EOF
  fi
  if [ ! -f "$STATE_FILE" ]; then
    cat >"$STATE_FILE" <<EOF
# State

- session: 0
- status: not started
- updated: $(stamp)

## Done

- (nothing yet)

## In progress

- (nothing yet)

## Next steps

1. (fill me in)

## Blockers / notes

- (none)
EOF
  fi
  [ -f "$WORKLOG_FILE" ] || printf '# Worklog (append-only, one entry per session)\n\n' >"$WORKLOG_FILE"
  printf 'initialized %s\n' "$DIR"
  printf '  task   %s\n' "$TASK_FILE"
  printf '  state  %s\n' "$STATE_FILE"
  printf 'edit the task, then run: %s start\n' "$(basename "$ABS_SELF")"
}

# ------------------------------------------------------------- budget (tick) --
cmd_budget() {
  local n deadline remaining elapsed left decision unchanged
  local timeout="${BABYSIT_SESSION_TIMEOUT:-$SESSION_TIMEOUT}"
  local maxsessions="${BABYSIT_MAX_SESSIONS:-$MAX_SESSIONS}"
  n="${BABYSIT_SESSION:-$(counter sessions_run)}"
  if [ -n "${BABYSIT_DEADLINE:-}" ]; then
    deadline="$BABYSIT_DEADLINE"
  elif [ -f "$DEADLINE_FILE" ]; then
    deadline="$(tr -dc '0-9' <"$DEADLINE_FILE")"
  else
    deadline=$(( $(now) + timeout ))
  fi
  remaining=$(( deadline - $(now) ))
  [ "$remaining" -lt 0 ] && remaining=0
  elapsed=$(( timeout - remaining ))
  [ "$elapsed" -lt 0 ] && elapsed=0
  left=$(( maxsessions - $(counter sessions_run) ))
  [ "$left" -lt 0 ] && left=0
  unchanged="$(counter stall_count)"

  if [ "$remaining" -le 60 ] || [ "$remaining" -le $(( timeout / 10 )) ]; then
    decision="handoff-now"
  elif [ "$remaining" -le $(( timeout * 3 / 10 )) ]; then
    decision="wrap-up-soon"
  else
    decision="continue"
  fi
  [ -f "$STOP_FILE" ] && decision="stop"
  [ -f "$DONE_FILE" ] && decision="stop"
  [ -f "$HALTED_FILE" ] && decision="stop"

  printf 'SESSION=%s (of %s max)\n' "$n" "$maxsessions"
  printf 'SESSION_ELAPSED=%ss  SESSION_TIMEOUT=%ss  REMAINING=%ss\n' "$elapsed" "$timeout" "$remaining"
  printf 'SESSIONS_LEFT=%s  CONSECUTIVE_FAILURES=%s\n' "$left" "$(counter consecutive_failures)"
  printf 'SESSIONS_WITHOUT_STATE_CHANGE=%s (stall limit %s)\n' "$unchanged" "$STALL_LIMIT"
  printf 'DECISION=%s\n' "$decision"
  if [ "$unchanged" -ge $(( STALL_LIMIT - 1 )) ] && [ "$STALL_LIMIT" -gt 0 ]; then
    printf 'WARNING=recent sessions did not change STATE.md -- change the approach, not the wording\n'
  fi
  return 0
}

# ------------------------------------------------------------------ running --
heartbeat() { mkdir -p "$DIR"; printf '%s session=%s\n' "$(now)" "$(counter sessions_run)" >"$HEARTBEAT"; }

state_hash() {
  if [ -f "$STATE_FILE" ]; then
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$STATE_FILE" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$STATE_FILE" | cut -d' ' -f1
    else wc -c <"$STATE_FILE" | tr -d ' '
    fi
  else
    printf 'none'
  fi
}

kill_tree() { # kill_tree <pgid-leader-pid> [TERM|KILL]
  local pid="$1" sig="${2:-TERM}"
  kill -"$sig" -- "-$pid" 2>/dev/null || kill -"$sig" "$pid" 2>/dev/null || true
}

wait_dead() { # wait_dead <pid> <seconds> -> 0 if dead
  local pid="$1" limit="$2" i=0
  while is_alive "$pid" && [ "$i" -lt "$limit" ]; do sleep 1; i=$((i + 1)); done
  is_alive "$pid" && return 1
  return 0
}

run_one_session() { # run_one_session <session-number>; sets SESSION_RC
  local n="$1" log rc=0 elapsed
  mkdir -p "$SESS_DIR"
  SESSION_RC=0

  build_prompt >"$PROMPT_FILE"
  log="$SESS_DIR/session-$(date -u +%Y%m%dT%H%M%S)-$(printf '%03d' "$n").log"
  printf '%s' "$log" >"$CURRENT_LOG_FILE"
  printf '%s' "$(( $(now) + SESSION_TIMEOUT ))" >"$DEADLINE_FILE"
  set_counter sessions_run "$n"
  heartbeat

  local CMD=()
  adapter_cmd "$(cat "$PROMPT_FILE")"

  # Own process group (setsid) so a timeout kills the agent AND everything it
  # spawned, not just the parent. PI_SESSION_* is unset so the worker creates
  # its own transcript instead of appending to the supervisor's.
  if command -v setsid >/dev/null 2>&1; then
    setsid env -u PI_SESSION_FILE -u PI_SESSION_ID \
      BABYSIT_DIR="$DIR" BABYSIT_SESSION="$n" BABYSIT_DEADLINE="$(cat "$DEADLINE_FILE")" \
      BABYSIT_SESSION_TIMEOUT="$SESSION_TIMEOUT" BABYSIT_MAX_SESSIONS="$MAX_SESSIONS" \
      BABYSIT_STALL_LIMIT="$STALL_LIMIT" \
      "${CMD[@]}" </dev/null >>"$log" 2>&1 &
  else
    env -u PI_SESSION_FILE -u PI_SESSION_ID \
      BABYSIT_DIR="$DIR" BABYSIT_SESSION="$n" BABYSIT_DEADLINE="$(cat "$DEADLINE_FILE")" \
      BABYSIT_SESSION_TIMEOUT="$SESSION_TIMEOUT" BABYSIT_MAX_SESSIONS="$MAX_SESSIONS" \
      BABYSIT_STALL_LIMIT="$STALL_LIMIT" \
      "${CMD[@]}" </dev/null >>"$log" 2>&1 &
  fi
  local spid=$!
  printf '%s' "$spid" >"$SESS_PID"
  printf '\n--- session %s started %s pid %s (timeout %ss) ---\n' \
    "$n" "$(stamp)" "$spid" "$SESSION_TIMEOUT" >>"$log"
  logline "session $n started pid=$spid timeout=${SESSION_TIMEOUT}s log=$log"

  while is_alive "$spid"; do
    heartbeat
    if [ -f "$DONE_FILE" ]; then
      printf 'babysit: done marker seen; ending session %s\n' "$n" >>"$log"
      kill_tree "$spid" TERM; rc=0; break
    fi
    if [ -f "$STOP_FILE" ]; then
      printf 'babysit: stop requested; ending session %s\n' "$n" >>"$log"
      kill_tree "$spid" TERM; rc=130; break
    fi
    if [ "$(now)" -ge "$(cat "$DEADLINE_FILE")" ]; then
      printf 'babysit: session timeout after %ss; ending pid %s\n' "$SESSION_TIMEOUT" "$spid" >>"$log"
      logline "session $n session timeout after ${SESSION_TIMEOUT}s; killing pid $spid"
      kill_tree "$spid" TERM; rc=124; break
    fi
    sleep 1
  done

  if [ "$rc" = 0 ]; then
    # Ended by itself: keep its real exit status.
    wait "$spid" 2>/dev/null || rc=$?
  else
    if ! wait_dead "$spid" "$KILL_GRACE"; then
      printf 'babysit: ignored SIGTERM after %ss; sending SIGKILL\n' "$KILL_GRACE" >>"$log"
      kill_tree "$spid" KILL
      wait_dead "$spid" 5 || true
    fi
    wait "$spid" 2>/dev/null || true
  fi
  rm -f "$SESS_PID"
  elapsed=$(( $(now) - ( $(cat "$DEADLINE_FILE") - SESSION_TIMEOUT ) ))
  [ "$elapsed" -lt 0 ] && elapsed=0
  printf '\n--- session %s exited rc=%s after %ss %s ---\n' "$n" "$rc" "$elapsed" "$(stamp)" >>"$log"
  logline "session $n exited rc=$rc elapsed=${elapsed}s"
  SESSION_RC="$rc"
}

note_result() { # update counters + progress after a session
  local rc="$1" h new
  h="$(state_hash)"
  new="$(cat "$STATE_HASH_FILE" 2>/dev/null || printf 'none')"
  if [ "$rc" -ne 0 ]; then
    set_counter consecutive_failures "$(( $(counter consecutive_failures) + 1 ))"
    if [ "$rc" = 124 ]; then
      logline "session hit the timeout; counted as a failure"
    fi
  else
    set_counter consecutive_failures 0
  fi
  if [ "$h" = "$new" ]; then
    set_counter stall_count "$(( $(counter stall_count) + 1 ))"
    logline "STATE.md unchanged after this session (stall_count=$(counter stall_count))"
  else
    set_counter stall_count 0
    printf '%s' "$h" >"$STATE_HASH_FILE"
    logline "STATE.md changed (progress)"
  fi
}

halt() { # halt <reason>
  mkdir -p "$DIR"
  printf '%s\n' "$*" >"$HALTED_FILE"
  logline "HALTED: $*"
  printf 'HALTED: %s\n' "$*" >&2
}

until_ok() { # 0 if the --until command says the task is done
  [ -n "$UNTIL_CMD" ] || return 1
  sh -c "$UNTIL_CMD" >/dev/null 2>&1
}

supervisor_pid() {
  [ -f "$SUP_PID" ] || return 1
  local p; p="$(tr -dc '0-9' <"$SUP_PID" 2>/dev/null)"
  [ -n "$p" ] || return 1
  is_alive "$p" || return 1
  printf '%s' "$p"
}

cmd_run() {
  local detach="no" foreground="no" passthru=() a
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      --detach)   detach="yes"; shift ;;
      --foreground) foreground="yes"; shift ;;
      --max-sessions) MAX_SESSIONS="${2:?}"; passthru+=(--max-sessions "$2"); shift 2 ;;
      --session-timeout) SESSION_TIMEOUT="${2:?}"; passthru+=(--session-timeout "$2"); shift 2 ;;
      --max-failures) MAX_FAILURES="${2:?}"; passthru+=(--max-failures "$2"); shift 2 ;;
      --stall-limit) STALL_LIMIT="${2:?}"; passthru+=(--stall-limit "$2"); shift 2 ;;
      --sleep) SLEEP_BETWEEN="${2:?}"; passthru+=(--sleep "$2"); shift 2 ;;
      --until) UNTIL_CMD="${2:?}"; passthru+=(--until "$2"); shift 2 ;;
      --harness) BABYSIT_HARNESS="${2:?}"; export BABYSIT_HARNESS; shift 2 ;;
      --model) BABYSIT_MODEL="${2:?}"; export BABYSIT_MODEL; shift 2 ;;
      --provider) BABYSIT_PROVIDER="${2:?}"; export BABYSIT_PROVIDER; shift 2 ;;
      *) printf 'ERROR: unknown option: %s\n' "$a" >&2; exit 2 ;;
    esac
  done

  [ -f "$TASK_FILE" ] || die "no $TASK_FILE -- run: $ABS_SELF init --task \"...\""
  mkdir -p "$DIR" "$SESS_DIR"

  if [ -f "$DONE_FILE" ]; then
    printf 'already done: %s\n' "$DONE_FILE"; exit 0
  fi

  # Watch that no other supervisor owns this DIR.
  local other; other="$(supervisor_pid || true)"
  if [ -n "$other" ] && [ "$other" != "$$" ]; then
    die "a supervisor is already running for $DIR (pid $other)"
  fi

  if [ "$detach" = "yes" ]; then
    if command -v setsid >/dev/null 2>&1; then
      setsid nohup "$ABS_SELF" run --foreground --dir "$DIR" "${passthru[@]+"${passthru[@]}"}" \
        >>"$SUP_LOG" 2>&1 </dev/null &
    else
      nohup "$ABS_SELF" run --foreground --dir "$DIR" "${passthru[@]+"${passthru[@]}"}" \
        >>"$SUP_LOG" 2>&1 </dev/null &
    fi
    local pid=$!
    printf '%s' "$pid" >"$SUP_PID"
    sleep 2
    if ! is_alive "$pid"; then
      printf 'FAILED: supervisor exited immediately. Log tail:\n' >&2
      tail -c 1200 "$SUP_LOG" >&2
      exit 1
    fi
    printf 'supervisor started (detached) pid=%s\n' "$pid"
    printf '  dir:  %s\n' "$DIR"
    printf '  log:  %s\n' "$SUP_LOG"
    printf '  watch:  %s status\n' "$ABS_SELF"
    printf '  stop:   %s stop --kill\n' "$ABS_SELF"
    exit 0
  fi

  printf '%s' "$$" >"$SUP_PID"
  heartbeat
  logline "supervisor start pid=$$ mode=${foreground} max_sessions=$MAX_SESSIONS timeout=${SESSION_TIMEOUT}s until='${UNTIL_CMD}'"

  # Seed the progress baseline so the first session is compared fairly.
  [ -f "$STATE_HASH_FILE" ] || state_hash >"$STATE_HASH_FILE"

  local stop_reason="" session_rc
  while :; do
    heartbeat
    if [ -f "$STOP_FILE" ]; then stop_reason="stopped by user"; break; fi
    if [ -f "$DONE_FILE" ]; then stop_reason="goal reached"; break; fi
    if [ -f "$HALTED_FILE" ]; then stop_reason="halted: $(cat "$HALTED_FILE")"; break; fi
    if until_ok; then
      printf '%s\n%s\n' "--until command succeeded" "$(stamp)" >"$DONE_FILE"
      logline "--until command succeeded; marking done"
      stop_reason="--until command succeeded"; break
    fi
    if [ "$(counter sessions_run)" -ge "$MAX_SESSIONS" ]; then
      halt "session budget exhausted ($(counter sessions_run)/$MAX_SESSIONS)"

      stop_reason="halted: budget exhausted"; break
    fi
    if [ "$(counter consecutive_failures)" -ge "$MAX_FAILURES" ]; then
      halt "$(counter consecutive_failures) consecutive session failures; last log: $CURRENT_LOG_FILE"
      stop_reason="halted: too many failures"; break
    fi
    if [ "$STALL_LIMIT" -gt 0 ] && [ "$(counter stall_count)" -ge "$STALL_LIMIT" ]; then
      halt "no progress: $STALL_LIMIT sessions in a row without changing STATE.md; change the approach or the task"
      stop_reason="halted: no progress"; break
    fi

    local n=$(( $(counter sessions_run) + 1 ))
    printf '\n=== session %s/%s starting %s ===\n' "$n" "$MAX_SESSIONS" "$(stamp)"
    run_one_session "$n"
    session_rc="$SESSION_RC"
    note_result "$session_rc"
    printf '=== session %s exited rc=%s (failures=%s stalls=%s) ===\n' \
      "$n" "$session_rc" "$(counter consecutive_failures)" "$(counter stall_count)"

    if [ -f "$DONE_FILE" ] || [ -f "$STOP_FILE" ] || [ -f "$HALTED_FILE" ]; then continue; fi
    [ "$SLEEP_BETWEEN" -gt 0 ] && sleep "$SLEEP_BETWEEN"
  done

  heartbeat
  logline "supervisor stop pid=$$ reason='$stop_reason' sessions=$(counter sessions_run)"
  rm -f "$SUP_PID"
  printf '\nsupervisor exiting: %s\n' "$stop_reason"
  printf '  sessions run: %s\n' "$(counter sessions_run)"
  printf '  status: %s\n' "$ABS_SELF status"
  if [ -f "$HALTED_FILE" ]; then exit 1; fi
  exit 0
}

cmd_once() {
  [ -f "$TASK_FILE" ] || die "no $TASK_FILE -- run: $ABS_SELF init --task \"...\""
  local other; other="$(supervisor_pid || true)"
  if [ -n "$other" ]; then die "a supervisor is already running (pid $other)"; fi
  mkdir -p "$DIR" "$SESS_DIR"
  [ -f "$STATE_HASH_FILE" ] || state_hash >"$STATE_HASH_FILE"
  heartbeat
  local n=$(( $(counter sessions_run) + 1 ))
  run_one_session "$n"
  set_counter sessions_run "$n"
  note_result "$SESSION_RC"
  printf 'session %s finished rc=%s\n' "$n" "$SESSION_RC"
  printf '  log: %s\n' "$(cat "$CURRENT_LOG_FILE")"
  return "$SESSION_RC"
}

# ------------------------------------------------------------------- status --
cmd_status() {
  local pid sesspid hb age now_s
  pid="$(supervisor_pid || true)"
  now_s="$(now)"
  printf 'project:    %s\n' "$PROJECT"
  printf 'dir:        %s\n' "$DIR"
  printf 'harness:    %s\n' "$(detect_harness)"
  if [ -n "$pid" ]; then
    printf 'supervisor: RUNNING (pid %s)\n' "$pid"
  else
    printf 'supervisor: not running\n'
  fi
  if [ -f "$SESS_PID" ]; then
    sesspid="$(tr -dc '0-9' <"$SESS_PID" 2>/dev/null)"
    if [ -n "$sesspid" ] && is_alive "$sesspid"; then
      printf 'session:    RUNNING (pid %s, session %s)\n' "$sesspid" "$(counter sessions_run)"
    else
      printf 'session:    none (stale session.pid)\n'
    fi
  else
    printf 'session:    none\n'
  fi
  if [ -f "$HEARTBEAT" ]; then
    hb="$(cut -d' ' -f1 <"$HEARTBEAT" | tr -dc '0-9')"
    [ -n "$hb" ] && age=$(( now_s - hb )) || age="?"
    if [ -n "$pid" ]; then
      printf 'heartbeat:  %ss ago\n' "$age"
    else
      printf 'heartbeat:  %ss ago (stale: supervisor not running)\n' "$age"
    fi
  fi
  printf 'sessions:   run=%s failures=%s stalls=%s left=%s\n' \
    "$(counter sessions_run)" "$(counter consecutive_failures)" \
    "$(counter stall_count)" "$(( MAX_SESSIONS - $(counter sessions_run) ))"
  printf 'stop:       %s\n' "$([ -f "$STOP_FILE" ] && echo 'YES (loop stopped by user)' || echo no)"
  printf 'done:       %s\n' "$([ -f "$DONE_FILE" ] && echo "YES ($(head -1 "$DONE_FILE"))" || echo no)"
  printf 'halted:     %s\n' "$([ -f "$HALTED_FILE" ] && echo "YES ($(head -1 "$HALTED_FILE"))" || echo no)"

  if [ -z "$pid" ] && [ ! -f "$STOP_FILE" ] && [ ! -f "$DONE_FILE" ] && [ ! -f "$HALTED_FILE" ]; then
    printf 'warning:    nothing is running and the task is not marked done or stopped.\n'
    printf '            restart with: %s start\n' "$ABS_SELF"
  fi
  if [ -f "$CURRENT_LOG_FILE" ]; then
    local last; last="$(cat "$CURRENT_LOG_FILE")"
    if [ -n "$last" ] && [ -f "$last" ]; then
      printf '\nlast session log: %s\n' "$last"
      tail -n 12 "$last" | sed 's/^/  /'
    fi
  fi
}

cmd_logs() { tail -n "${1:-40}" "$SUP_LOG" 2>/dev/null || printf '(no log yet)\n'; }

cmd_tail() {
  local last; last="$(cat "$CURRENT_LOG_FILE" 2>/dev/null || true)"
  [ -n "$last" ] && [ -f "$last" ] || die "no session log yet"
  tail -n "${1:-40}" -f "$last"
}

cmd_done() {
  local note="goal reached"
  while [ $# -gt 0 ]; do
    case "$1" in --note) note="${2:-}"; shift 2 ;; *) shift ;; esac
  done
  mkdir -p "$DIR"
  printf '%s\n%s\n' "$note" "$(stamp)" >"$DONE_FILE"
  logline "DONE: $note"
  printf 'marked done: %s\n' "$note"
}

cmd_halt() {
  local reason="halted by a session"
  while [ $# -gt 0 ]; do
    case "$1" in --reason) reason="${2:-}"; shift 2 ;; *) shift ;; esac
  done
  halt "$reason"
}

cmd_stop() {
  mkdir -p "$DIR"; touch "$STOP_FILE"
  printf 'stop file created: %s\n' "$STOP_FILE"
  if [ "${1:-}" = "--kill" ]; then
    local sesspid
    if [ -f "$SESS_PID" ]; then
      sesspid="$(tr -dc '0-9' <"$SESS_PID")"
      if [ -n "$sesspid" ] && is_alive "$sesspid"; then
        kill_tree "$sesspid" TERM
        printf 'sent SIGTERM to session pid %s\n' "$sesspid"
      fi
    fi
    local pid; pid="$(supervisor_pid || true)"
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null && printf 'sent SIGTERM to supervisor pid %s\n' "$pid"
    fi
  else
    printf 'the running session finishes; no new session starts. remove with: %s resume\n' "$ABS_SELF"
  fi
}

cmd_resume() {
  rm -f "$STOP_FILE" "$HALTED_FILE"
  set_counter consecutive_failures 0
  set_counter stall_count 0
  printf 're-armed (%s and %s removed)\n' "$STOP_FILE" "$HALTED_FILE"
}

cmd_reset() {
  if [ "${1:-}" != "--yes" ]; then
    die "reset wipes runtime state; confirm with: $ABS_SELF reset --yes"
  fi
  rm -rf "$SESS_DIR"
  rm -f "$SUP_PID" "$SESS_PID" "$HEARTBEAT" "$DEADLINE_FILE" "$STOP_FILE" \
        "$DONE_FILE" "$HALTED_FILE" "$COUNTERS" "$STATE_HASH_FILE" "$CURRENT_LOG_FILE" \
        "$PROMPT_FILE" "$SUP_LOG"
  mkdir -p "$SESS_DIR"
  printf 'sessions_run=0\nconsecutive_failures=0\nstall_count=0\n' >"$COUNTERS"
  printf 'reset runtime state in %s (TASK.md, STATE.md and WORKLOG.md kept)\n' "$DIR"
}

cmd_detect() {
  local h; h="$(detect_harness)"
  printf 'harness=%s\n' "$h"
  printf 'project=%s\n' "$PROJECT"
  printf 'dir=%s\n' "$DIR"
  printf 'installed:'
  local c; for c in pi opencode codex claude; do
    command -v "$c" >/dev/null 2>&1 && printf ' %s' "$c"
  done
  printf '\n'
}

usage() {
  sed -n '2,50p' "$ABS_SELF" | sed 's/^# \{0,1\}//'
}

case "${1:-help}" in
  detect) cmd_detect ;;
  init)   cmd_init "${@:2}" ;;
  run|start)
          if [ "${1}" = "start" ]; then shift; cmd_run --detach "$@"; else shift; cmd_run "$@"; fi ;;
  once)   cmd_once ;;
  budget|tick) cmd_budget ;;
  print)  build_prompt ;;
  status) cmd_status ;;
  logs)   cmd_logs "${2:-40}" ;;
  tail)   cmd_tail "${2:-40}" ;;
  done)   cmd_done "${@:2}" ;;
  halt)   cmd_halt "${@:2}" ;;
  stop)   cmd_stop "${2:-}" ;;
  resume) cmd_resume ;;
  reset)  cmd_reset "${2:-}" ;;
  help|-h|--help) usage ;;
  *) printf 'unknown command: %s\n\n' "${1:-}" >&2; usage >&2; exit 2 ;;
esac
