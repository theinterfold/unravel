#!/usr/bin/env bash
#
# Brings up a CRISP devnet.
#
# Defaults to the standard ports (anvil 8545, program server 13151, ciphernodes 9201-9205) because
# that is what every wallet and tool already expects — MetaMask ships a "Localhost 8545" network,
# and pointing it anywhere else is a step people forget, producing a NetworkError that reads like a
# contract revert.
#
# Set ANVIL_PORT to something else to run an isolated stack beside an existing devnet; every other
# port shifts with it so the two do not collide.
#
# This deliberately does NOT use `pnpm dev:up`. That script hardcodes 8545, and its cleanup trap
# runs `pkill -9 -f anvil` / `pkill -9 -f "interfold start"` — which match by process name, so it
# tears down every anvil and every ciphernode on the machine, not just its own.
#
# IMPORTANT: port isolation is one-directional. Nothing here can stop *another* stack's teardown
# from killing this one, because that teardown is also name-based. If a neighbouring devnet
# restarts while this is running, this stack dies with it (anvil exits 137).
#
# Usage: bring-up.sh
set -euo pipefail

CRISP_DIR="${CRISP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../interfold/.claude/worktrees/survival-game/examples/CRISP" && pwd)}"
PORT="${ANVIL_PORT:-8545}"
RPC="http://127.0.0.1:${PORT}"
LOGS="${LOGS:-/tmp/unravel-devnet}"

# Standard ports when on 8545, shifted when running isolated beside another stack.
if [ "$PORT" = "8545" ]; then
  PROGRAM_PORT="${PROGRAM_SERVER_PORT:-13151}"
  QUIC_PREFIX=920; CTRL_PREFIX=505; DASHBOARD_PORT=8080
else
  PROGRAM_PORT="${PROGRAM_SERVER_PORT:-13152}"
  QUIC_PREFIX=930; CTRL_PREFIX=506; DASHBOARD_PORT=8081
fi

mkdir -p "$LOGS"
step() { printf '\n\033[1m>>> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

cd "$CRISP_DIR"

step "starting anvil on $PORT"
anvil --host 127.0.0.1 --port "$PORT" --chain-id 31337 --block-time 1 \
  --mnemonic 'test test test test test test test test test test test junk' --silent \
  > "$LOGS/anvil.log" 2>&1 &
until cast block-number --rpc-url "$RPC" >/dev/null 2>&1; do sleep 1; done
echo "anvil up at block $(cast block-number --rpc-url "$RPC" 2>/dev/null)"

step "deploying CRISP contracts"
# RPC_URL is honoured by both hardhat configs' `localhost` network. Without it they silently
# target 8545 and would deploy onto (or transact against) the neighbouring chain.
RPC_URL="$RPC" bash ./scripts/crisp_deploy.sh > "$LOGS/deploy.log" 2>&1 ||
  { tail -20 "$LOGS/deploy.log"; fail "contract deploy failed"; }
echo "deployed"

step "pointing the stack at $PORT"
# Rewrites are idempotent: they match whatever port is currently configured rather than the stock
# value, so switching between 8545 and an isolated port works in either direction and repeatedly.
# Matching only the original values would silently leave a previous remap in place.
sed -E -i '' \
  -e "s|rpc_url: ws://localhost:[0-9]+|rpc_url: ws://localhost:${PORT}|" \
  -e "s|quic_port: [0-9]{2}0([0-9])|quic_port: ${QUIC_PREFIX}\1|" \
  -e "s|ctrl_port: [0-9]{3}0([0-9])|ctrl_port: ${CTRL_PREFIX}0\1|" \
  -e "s|dashboard_port: [0-9]+|dashboard_port: ${DASHBOARD_PORT}|" \
  -e "s|/udp/[0-9]{2}0([0-9])/quic-v1|/udp/${QUIC_PREFIX}\1/quic-v1|" \
  interfold.config.yaml

sed -E -i '' \
  -e "s|HTTP_RPC_URL=http://127.0.0.1:[0-9]+|HTTP_RPC_URL=${RPC}|" \
  -e "s|WS_RPC_URL=ws://127.0.0.1:[0-9]+|WS_RPC_URL=ws://127.0.0.1:${PORT}|" \
  -e "s|PROGRAM_SERVER_URL=http://127.0.0.1:[0-9]+|PROGRAM_SERVER_URL=http://127.0.0.1:${PROGRAM_PORT}|" \
  server/.env

grep -E "rpc_url:|quic_port:" interfold.config.yaml | head -2
grep -E "HTTP_RPC_URL|PROGRAM_SERVER_URL" server/.env

step "registering ciphernodes"
# dev_cipher.sh registers the nodes and starts the swarm, but its EXIT trap kills the swarm on the
# way out — so it is used only for registration, and the swarm is started separately below.
rm -f ./.interfold/ready
# dev_cipher.sh ends in `wait` and never returns, so it has to run in the background and be
# watched via its readyfile rather than its exit status.
RPC_URL="$RPC" ./scripts/dev_cipher.sh ./.interfold/ready > "$LOGS/cipher.log" 2>&1 &
CIPHER_PID=$!
until [ -f ./.interfold/ready ] || ! kill -0 "$CIPHER_PID" 2>/dev/null; do sleep 3; done
[ -f ./.interfold/ready ] || { tail -20 "$LOGS/cipher.log"; fail "ciphernode registration failed"; }

# Stop it now that registration is done: its EXIT trap kills the swarm it started, so the swarm has
# to be (re)started separately below to outlive this script.
kill -TERM "$CIPHER_PID" 2>/dev/null || true
wait "$CIPHER_PID" 2>/dev/null || true
echo "registered"

step "starting the ciphernode swarm"
interfold nodes down >/dev/null 2>&1 || true
interfold nodes up -v > "$LOGS/nodes.log" 2>&1 &
until lsof -nP -i:"${QUIC_PREFIX}1" >/dev/null 2>&1; do sleep 2; done
echo "swarm up"

step "starting the program server on $PROGRAM_PORT"
PROGRAM_SERVER_PORT="$PROGRAM_PORT" ./scripts/dev_program.sh > "$LOGS/program.log" 2>&1 &
until lsof -nP -iTCP:"$PROGRAM_PORT" -sTCP:LISTEN >/dev/null 2>&1; do sleep 3; done
echo "program server up"

step "starting the coordination server"
./scripts/dev_server.sh > "$LOGS/server.log" 2>&1 &
until lsof -nP -iTCP:4000 -sTCP:LISTEN >/dev/null 2>&1; do sleep 3; done
echo "coordination server up"

step "ready — logs in $LOGS"
echo "run a round with: scripts/devnet/run-round.sh 4"
