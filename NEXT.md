# NEXT.md — pick this up here

Session 1 · 2026-09-17 · `/root/babysit-sh`

This file is the handoff between sessions of *this* project. If you are a fresh
agent session: read this first, then `README.md`, then `babysit.sh`.

## What this is

`babysit-sh` — an agent-agnostic supervisor for long-running agent tasks. An
external supervisor process starts fresh worker sessions one after another until
the task is done, the budget runs out, or a human stops it. It is the inverse of
`../agent-loop` (there the agent hands off to itself; here the supervisor owns
succession, so a worker cannot break the chain).

## State: working and tested

| file | state |
| --- | --- |
| `babysit.sh` | **working.** ~660 lines, shellcheck `-S warning` clean |
| `test/run-tests.sh` | **working, 62 checks, all passing**, ~90s, stub sessions only, no network |
| `install.sh` | **working**, both checkout and `curl \| bash` (tested offline via `BABYSIT_RAW_BASE=file://...`) |
| `babysit.md` | entry-point prompt for an agent to set up a supervised task (no driver appendix yet) |
| `README.md` | design + reference |
| `LICENSE` | MIT |
| `.github/workflows/ci.yml` | shellcheck + tests |

Verified manually this session: three supervised sessions → `done` marker →
supervisor exits 0; `start` detached survives the launching shell; `stop --kill`
kills the session process group; timeout kill; stall halt; failure halt.

**Not yet done: nothing is pushed to GitHub. `git init` has not even been run.**

## Commands that must stay green

```bash
shellcheck -S warning babysit.sh install.sh test/run-tests.sh
./test/run-tests.sh
```

## Next session, in order

1. **Create the repo and push** (needs a visibility decision from the human —
   public is required for anonymous `curl | bash`):
   ```bash
   cd /root/babysit-sh
   git init -b main && git add -A && git commit -m "..."
   gh repo create vvanghelue/babysit-sh --public --source=. --remote=origin --push
   git tag v0.1.0 && git push --tags
   ```
2. **Trap `TERM`/`INT` in the supervisor.** Today `stop --kill` kills it
   abruptly: `supervisor.pid` and `heartbeat` go stale and there is no final
   `supervisor.log` line. Add `trap on_term TERM INT` that kills the current
   session group, writes a logline, removes `supervisor.pid`, and exits 143.
   Add a test for it (section 10 currently only asserts it stops).
3. **Embed the driver in `babysit.md`** as an `<!-- BEGIN babysit.sh -->`
   appendix plus a `build-babysit-md.sh --check`, the way agent-loop does it, so
   the entry-point prompt is self-contained. Wire `--check` into CI.
4. **Live smoke test with the real `pi` CLI** (`babysit.sh once` on a trivial
   task) — manual, not in CI. Then the same for opencode/codex/claude and
   update the status table in `README.md`.
5. **Per-session records**: a `sessions/<n>.json` line (start, end, rc, elapsed,
   state hash, tokens if the harness exposes them) plus `babysit.sh report`.
6. **`systemd` unit example** and a `babysit.sh install-unit` helper — the
   supervisor is designed to be a process, so sell that.
7. **Multi-task registry** (a real "manager"): optionally track known
   `.babysit` dirs in `$HOME/.babysit/tasks` and add `babysit.sh ls` / `all-status`.

## Decisions already made — keep them

- **The supervisor starts sessions, the worker never does.** This is the whole
  point; do not add an "agent hands off" mode.
- **Time-based budget, not turn-based.** The supervisor enforces wall clock, so
  `budget` reports remaining seconds and `DECISION=handoff-now` near the
  deadline. (agent-loop counts turns because it has no supervisor.)
- **Progress is `STATE.md` hashing** → stall; **exit code** → failure; both halt
  loudly with a reason in `HALTED`. Do not make "no state change" silently retry.
- **One `.babysit` directory = one task = one supervisor process.** `--dir` is
  global (pre-parsed before dispatch).
- **Everything overridable by env**, because CI and tests depend on it.
- Worker sessions get `setsid` (own process group, killable as a tree) and have
  `PI_SESSION_FILE`/`PI_SESSION_ID` unset so they get their own transcripts.

## Known gaps / things to fix

- No `TERM`/`INT` trap (see item 2). `HALTED`/`DONE` don't get a final logline
  when the supervisor is killed directly.
- `install.sh` treats a missing `babysit.md` at the ref as fatal (the whole
  install fails). Consider warning instead and continuing with `--driver-only`
  behaviour, or download the prompt after `init` succeeds (it already is after,
  but `fetch` failure under `set -e` still aborts).
- `once` ignores existing `DONE`/`stop` markers — it always runs one session.
  Decide and document (arguably it should refuse like `run` does).
- `README.md` said "53 checks"; the real number is now **62**. Keep the counts of
  README and `NEXT.md` in sync with the suite, or drop the number.
- `supervisor_pid` trusts `kill -0` only (PID reuse) — same trade as agent-loop.
- No test asserts the *worker prompt actually reaches the CLI*; tests use
  `BABYSIT_CMD` without `@@PROMPT@@`. Consider one check with
  `BABYSIT_CMD='cat @@PROMPT_FILE@@'` asserting the contract text lands in the log.

## Open questions for the human

- Public or private repo? (`vvanghelue/babysit-sh` appears free; `gh` is
  authenticated as `vvanghelue`.)
- Is "one supervisor per task" enough, or is the wanted product a **manager**
  that owns many long tasks at once (item 7)?
- Name: `babysit-sh` keeps the repo name honest; `babysit` is a nicer CLI name
  (the installed driver is already `.babysit/babysit.sh`).