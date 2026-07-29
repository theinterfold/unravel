#!/usr/bin/env bash
#
# Stops this devnet and nothing else.
#
# Deliberately does NOT use `pkill -f anvil` or `pkill -f "interfold start"`, which is how CRISP's
# own dev.sh tears down: those match by process name, so they kill every anvil and every ciphernode
# on the machine — including another project's devnet. This kills only what is bound to this
# stack's ports.
#
# Usage: teardown.sh
set -euo pipefail

PORT="${ANVIL_PORT:-8546}"
PROGRAM_PORT="${PROGRAM_SERVER_PORT:-13152}"
SERVER_PORT="${CRISP_SERVER_PORT:-4000}"
CRISP_DIR="${CRISP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../interfold/.claude/worktrees/survival-game/examples/CRISP" && pwd)}"

step() { printf '\n\033[1m>>> %s\033[0m\n' "$*"; }

step "stopping the ciphernode swarm"
# `interfold nodes down` is scoped by the node names in interfold.config.yaml (cn1-cn5). If another
# stack uses the same names it may be affected, so it is run from this stack's directory where its
# own config and data live.
(cd "$CRISP_DIR" && interfold nodes down >/dev/null 2>&1) || true
echo "  done"

step "stopping services by port"
for p in "$PORT" "$PROGRAM_PORT" "$SERVER_PORT"; do
  pid="$(lsof -nP -iTCP:"$p" -sTCP:LISTEN -t 2>/dev/null | head -1)"
  [ -z "$pid" ] && pid="$(lsof -nP -i:"$p" -t 2>/dev/null | head -1)"
  if [ -n "$pid" ]; then
    kill -TERM "$pid" 2>/dev/null && echo "  port $p: stopped pid $pid"
  else
    echo "  port $p: already free"
  fi
done

sleep 2

step "remaining"
for p in "$PORT" "$PROGRAM_PORT" "$SERVER_PORT" 9301 9302 9303 9304 9305; do
  lsof -nP -i:"$p" >/dev/null 2>&1 && echo "  $p STILL UP" || true
done
echo "  (nothing listed above means everything stopped)"
