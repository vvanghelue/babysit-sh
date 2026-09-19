<!--
HOW TO USE THIS FILE (for the human, not for the agent)

  This is the entry-point prompt for babysit-sh. Hand it to any coding agent to
  set up and start a supervised long-running task:

    pi       --approve -p "$(cat babysit.md)"
    opencode run --auto "$(cat babysit.md)"
    codex    exec --sandbox workspace-write "$(cat babysit.md)"
    claude   -p "$(cat babysit.md)" --permission-mode bypassPermissions

  Or install by hand and skip the agent entirely:

    curl -fsSL https://raw.githubusercontent.com/vvanghelue/babysit-sh/main/install.sh | bash
    $EDITOR .babysit/tasks/main/TASK.md
    .babysit/babysit.sh start

  The agent is not the loop here. The *supervisor* is: .babysit/babysit.sh keeps
  starting fresh worker sessions until the task in TASK.md is done. This file
  only bootstraps that supervisor and writes the task down properly. One project
  has one .babysit/ directory; each task lives in .babysit/tasks/<name>/ and has
  its own supervisor, so several long tasks can run side by side.
-->

# babysit-sh — set up a supervised long-running task

You are an AI coding agent. Your job in this session is **not** to do the task.
Your job is to set up a supervisor that will run the task as a long chain of
fresh worker sessions, then hand control to it and stop.

The important difference from a self-continuing loop: **the supervisor owns the
succession, not the worker.** Worker sessions are disposable. If one crashes,
times out, spins or forgets to write state, the supervisor notices and acts. A
worker cannot break the chain.

---

## 1. Install the supervisor if it is missing

Check for `.babysit/babysit.sh` in the project root. If it is not there:

```bash
curl -fsSL https://raw.githubusercontent.com/vvanghelue/babysit-sh/main/install.sh | bash -s -- .
```

That writes `.babysit/babysit.sh` plus the default task
(`.babysit/tasks/main/TASK.md`, `.babysit/tasks/main/STATE.md` and
`.babysit/tasks/main/WORKLOG.md`), and registers the project-level convention in
`AGENTS.md` (plus a `CLAUDE.md` that imports it), so that **every future agent
session in this project knows what "Using babysit, ..." means**. If you have a
checkout of this repo, `./install.sh .` does the same thing, and `--link`
symlinks instead of copying. Pass `--no-agents` to skip the `AGENTS.md` update.

Verify it:

```bash
.babysit/babysit.sh detect
.babysit/babysit.sh agents-md --check
```

If you installed the driver by hand, register the convention explicitly:

```bash
.babysit/babysit.sh agents-md --write
```

From then on the human only has to say **"Using babysit, <goal>"** and the next
agent session — primed by `AGENTS.md` — writes `TASK.md` and starts the
supervisor. That is a *different* session from this one: you are setting the
table, not eating.

One project can host several long tasks at once. They all live under the single
`.babysit/` directory, one per name, each with its own supervisor:

```bash
.babysit/babysit.sh init --task migrate-db --goal "migrate the database"
.babysit/babysit.sh start --task migrate-db
.babysit/babysit.sh ls            # every task, and whether it is running
```

If you do not pass `--task`, everything defaults to the task named `main`.

---

## 2. Write the task properly

`.babysit/tasks/<name>/TASK.md` (the default task is `main`) is the only thing
every worker session reads on every start. It must state:

- **the goal** — the end state, not the activity
- **the definition of done** — something observable and testable, because the
  supervisor stops on `babysit.sh done`, and a vague definition is how a loop
  runs for hours without finishing
- **constraints** — what must not happen, what is expensive, what to skip
- **notes for workers** — anything a fresh session would otherwise re-derive

Edit `.babysit/tasks/main/TASK.md` now. Also seed
`.babysit/tasks/main/STATE.md` with what you already know: what exists, what is
already done, the first concrete next step, and any blockers. Do not leave it as
a template — the first worker session will believe whatever is in there.

If you need the supervisor to stop without any worker cooperating, you can also
give it a completion probe:

```bash
.babysit/babysit.sh start --until "test -f out/report.json"
```

`--until CMD` is run after every session; when it exits 0 the supervisor marks
the task done and stops. This is the most reliable definition of done there is.

---

## 3. Choose the budget for a long task

The supervisor's defaults are for a task that runs for hours:

| flag | default | meaning |
| --- | --- | --- |
| `--max-sessions N` | 100 | hard cap on how many worker sessions to spend |
| `--session-timeout S` | 3600 | kill a worker that runs longer than this |
| `--max-failures N` | 5 | consecutive failures before it halts |
| `--stall-limit N` | 3 | sessions with no `STATE.md` change before it halts |
| `--sleep S` | 5 | pause between sessions |

Adjust them to the task and say why in `STATE.md`. A task that needs 10 minutes
of work does not need 100 sessions; a migration that runs overnight does.

---

## 4. Start the supervisor and get out of the way

```bash
.babysit/babysit.sh start            # detached; survives this shell (task main)
```

For a second task, give it a name and pass `--task` to every command:

```bash
.babysit/babysit.sh init --task migrate-db --goal "..."
.babysit/babysit.sh start --task migrate-db
```

Then:

```bash
.babysit/babysit.sh ls               # every task and whether it is running
.babysit/babysit.sh status           # alive? which session? heartbeat?
.babysit/babysit.sh status --task migrate-db
.babysit/babysit.sh tail             # follow the current worker session
.babysit/babysit.sh logs 60          # supervisor decisions and exits
.babysit/babysit.sh stop --kill      # human kill switch
.babysit/babysit.sh resume           # clear a stop/halt and re-arm
```

Do **not** babysit it yourself. Do not poll it, do not `wait` for it, do not
start worker sessions by hand. Reply to the user with the task, the budget, and
the three commands to watch/stop it, then end your turn. Also tell the user that
in this project they can start further long tasks by saying **"Using babysit,
<goal>"** — the `AGENTS.md` block you just wrote makes that work.

---

## 5. What every worker session is told

The supervisor hands each session a contract plus `TASK.md`. It tells them:

- read `TASK.md`, `STATE.md` and `WORKLOG.md` before touching anything
- check the time budget with `babysit.sh budget` (`DECISION=handoff-now` means
  write state and exit immediately — the supervisor is about to kill the session)
- leave the workspace working: a half-applied edit is worse than doing less
- rewrite `STATE.md` and append one `WORKLOG.md` entry before exiting
- `babysit.sh done --note "..."` when the goal is reached
- `babysit.sh halt --reason "..."` when genuinely blocked
- **never** launch another session, never wait, never sleep to stay alive —
  exiting *is* the handoff

That contract lives in `babysit.sh` (`build_contract`). If you change the rules
of the loop, change them there so every future worker inherits them.

---

## 6. If something is wrong

- `status` says `supervisor: not running` but the task is not done or stopped:
  the supervisor died. Read `.babysit/tasks/<name>/supervisor.log` (run
  `.babysit/babysit.sh ls` if you are not sure which task), fix the cause, and
  `start` again. `STATE.md` still holds the progress.
- `halted: no progress` — several sessions changed nothing. The task or the
  approach is wrong, not the wording. Rewrite `TASK.md`, `resume`, `start`.
- `halted: ... consecutive session failures` — read the last session log; that
  is usually a harness/model/CLI problem, not a task problem.
- A worker keeps timing out — raise `--session-timeout` or write a tighter
  "notes for workers" section so sessions cut their work smaller.