#!/usr/bin/env bash
# =============================================================================
# babysit-sh installer.
#
# From a checkout:
#
#   ./install.sh [project-dir] [--link]
#
# Straight from GitHub:
#
#   curl -fsSL https://raw.githubusercontent.com/vvanghelue/babysit-sh/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/vvanghelue/babysit-sh/main/install.sh \
#     | bash -s -- ~/my-project --ref v0.1.0
#
# Options:
#   --ref REF           git ref to download: branch, tag or commit (default: main)
#   --repo OWNER/NAME   source repository (default: vvanghelue/babysit-sh)
#   --link              symlink the driver instead of copying it (checkout only)
#   --driver-only       do not download the entry-point prompt
#   --no-agents         do not register the "Using babysit" trigger in AGENTS.md
#   -h | --help         this text
#
# AGENT_LOOP_RAW_BASE / BABYSIT_RAW_BASE override the download base URL (used by
# the test suite to exercise this script without a network).
# =============================================================================
set -euo pipefail

REPO="vvanghelue/babysit-sh"
REF="main"
PROJECT=""
MODE="copy"
DRIVER_ONLY="no"
AGENTS="yes"

usage() {
  cat <<'EOF'
babysit-sh installer.

From a checkout:
  ./install.sh [project-dir] [--link]

Straight from GitHub:
  curl -fsSL https://raw.githubusercontent.com/vvanghelue/babysit-sh/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/vvanghelue/babysit-sh/main/install.sh \
    | bash -s -- ~/my-project --ref v0.1.0

Options:
  --ref REF           git ref to download: branch, tag or commit (default: main)
  --repo OWNER/NAME   source repository (default: vvanghelue/babysit-sh)
  --link              symlink the driver instead of copying it (checkout only)
  --driver-only       do not download the entry-point prompt
  --no-agents         do not register the "Using babysit" trigger in AGENTS.md
  -h | --help         this text
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --link)        MODE="link" ;;
    --ref)         REF="${2:?--ref needs a value}"; shift ;;
    --repo)        REPO="${2:?--repo needs a value}"; shift ;;
    --driver-only) DRIVER_ONLY="yes" ;;
    --no-agents)   AGENTS="no" ;;
    -h|--help)     usage; exit 0 ;;
    -*)            printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 2 ;;
    *)             PROJECT="$1" ;;
  esac
  shift
done

RAW="${BABYSIT_RAW_BASE:-${AGENT_LOOP_RAW_BASE:-https://raw.githubusercontent.com/$REPO/$REF}}"

SELF="${BASH_SOURCE[0]:-}"
SELF_DIR=""
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
  SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
fi
LOCAL="no"
if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/babysit.sh" ]; then LOCAL="yes"; fi

if [ "$MODE" = "link" ] && [ "$LOCAL" != "yes" ]; then
  printf 'ERROR: --link needs a checkout; a piped install always copies.\n' >&2
  exit 1
fi

PROJECT="${PROJECT:-$(pwd)}"
PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd)" || {
  printf 'ERROR: no such directory: %s\n' "${PROJECT:-}" >&2; exit 1; }

mkdir -p "$PROJECT/.babysit"
DRIVER="$PROJECT/.babysit/babysit.sh"

fetch() { # fetch <remote-path> <local-path>
  local url="$RAW/$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    printf 'ERROR: need curl or wget to download from GitHub\n' >&2
    exit 1
  fi
}

if [ "$LOCAL" = "yes" ] && [ "$MODE" = "link" ]; then
  ln -sfn "$SELF_DIR/babysit.sh" "$DRIVER"
elif [ "$LOCAL" = "yes" ]; then
  cp "$SELF_DIR/babysit.sh" "$DRIVER"
else
  printf 'downloading %s/babysit.sh\n' "$RAW"
  fetch babysit.sh "$DRIVER"
fi
chmod +x "$DRIVER"

# A 404 page or a wrong ref must never be installed: this driver starts agents
# with permission checks disabled.
if ! head -1 "$DRIVER" | grep -q '^#!/usr/bin/env bash'; then
  printf 'ERROR: %s does not look like the babysit driver (bad ref?)\n' "$DRIVER" >&2
  exit 1
fi
if ! bash -n "$DRIVER" 2>/dev/null; then
  printf 'ERROR: downloaded driver failed the syntax check\n' >&2
  exit 1
fi

BABYSIT_PROJECT="$PROJECT" "$DRIVER" init >/dev/null

ENTRYPOINT="$PROJECT/.babysit/ENTRYPOINT.md"
if [ "$DRIVER_ONLY" != "yes" ]; then
  if [ "$LOCAL" = "yes" ] && [ -f "$SELF_DIR/babysit.md" ]; then
    cp "$SELF_DIR/babysit.md" "$ENTRYPOINT"
  else
    printf 'downloading %s/babysit.md\n' "$RAW"
    fetch babysit.md "$ENTRYPOINT"
  fi
fi

# Register the project-level convention so that, from now on, any agent session
# in this project understands "Using babysit, <goal>" without being told again.
if [ "$AGENTS" = "yes" ] && [ "$DRIVER_ONLY" != "yes" ]; then
  BABYSIT_PROJECT="$PROJECT" "$DRIVER" agents-md \
    || printf 'WARNING: could not update AGENTS.md; run: %s agents-md --write\n' "$DRIVER" >&2
fi

sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else printf 'n/a'
  fi
}

printf '\ninstalled (%s) into %s/.babysit\n' "$MODE" "$PROJECT"
if [ "$LOCAL" = "yes" ]; then
  printf '  source: %s\n' "$SELF_DIR"
else
  printf '  source: %s @ %s\n' "$REPO" "$REF"
fi
printf '  driver: %s\n' "$DRIVER"
printf '  sha256: %s\n' "$(sha "$DRIVER")"

cat <<EOF

next:
  1. write the task (goal + definition of done) in
       $PROJECT/.babysit/tasks/main/TASK.md
  2. start the supervisor:

       cd $PROJECT && .babysit/babysit.sh start      # detached, task main
       cd $PROJECT && .babysit/babysit.sh run        # foreground, watch it

     watch:  cd $PROJECT && .babysit/babysit.sh status
     list:   cd $PROJECT && .babysit/babysit.sh ls
     logs:   cd $PROJECT && .babysit/babysit.sh tail
     stop:   cd $PROJECT && .babysit/babysit.sh stop --kill

  several long tasks run side by side under one .babysit/: give each one a name
  and pass --task NAME to init/start/status (the default task is main).

from now on, in this project, tell your agent "Using babysit, <goal>" and it
will write TASK.md and start the supervisor for you (AGENTS.md was updated).
EOF