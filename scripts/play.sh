#!/usr/bin/env bash
#
# One command: devnet -> game deployed -> pot funded -> app configured -> frontend running.
#
# The point is that nothing here should need to be done by hand. Everything it does was previously
# a step you had to remember, and several of them fail silently if skipped — an unfunded pot cannot
# pay an E3 fee, and an empty COMPUTE_PROVIDER_PARAMS makes getE3Quote revert with empty data.
#
#   ./scripts/play.sh              # full bootstrap, then serve the app
#   ./scripts/play.sh --no-app     # bootstrap only (leaves the stack up)
#   ./scripts/play.sh --reuse      # keep the running devnet, just deploy a fresh game
#
# Env overrides: ROSTER, CAMPAIGN_DURATION, BALLOT_DURATION, TALLY_GRACE, ANVIL_PORT, APP_PORT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRISP_DIR="${CRISP_DIR:-$(cd "$ROOT/../interfold/.claude/worktrees/survival-game/examples/CRISP" && pwd)}"

PORT="${ANVIL_PORT:-8546}"
RPC="http://127.0.0.1:${PORT}"
CRISP_SERVER="${CRISP_SERVER_URL:-http://127.0.0.1:4000}"
APP_PORT="${APP_PORT:-3000}"

ROSTER="${ROSTER:-4}"
# Long by default. The committee key takes ~290s to publish, and the ballot window has to fit a
# human driving several wallets through browser proof generation at ~45-90s each — a window sized
# for a script is unusable by hand.
CAMPAIGN_DURATION="${CAMPAIGN_DURATION:-900}"
BALLOT_DURATION="${BALLOT_DURATION:-900}"
TALLY_GRACE="${TALLY_GRACE:-300}"

START_APP=true
REUSE=false
for arg in "$@"; do
  case "$arg" in
    --no-app) START_APP=false ;;
    --reuse) REUSE=true ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m>>> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER_ADDR=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
# Serialised ComputeProviderParams {"name":"RISC0","parallel":false,"batch_size":4}. Required —
# empty bytes make the Interfold fee quote revert with no reason data.
COMPUTE_PROVIDER_PARAMS=0x7b226e616d65223a225249534330222c22706172616c6c656c223a66616c73652c2262617463685f73697a65223a347d

# ─── 0. preflight ───────────────────────────────────────────────────────────────────────────────
#
# Checked before anything is started, because bringing the devnet up takes several minutes and
# discovering a missing tool at the end of that is pure waste.

for bin in cast forge; do
  command -v "$bin" >/dev/null 2>&1 || fail "$bin not found — install Foundry"
done

# ─── 1. devnet ──────────────────────────────────────────────────────────────────────────────────

if cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
  if [ "$REUSE" = true ]; then
    step "reusing the devnet already running on $PORT"
  else
    fail "something is already listening on $PORT. Use --reuse to deploy onto it, or run scripts/devnet/teardown.sh first."
  fi
else
  [ "$REUSE" = false ] || fail "--reuse given but no chain at $RPC"
  step "bringing up the devnet (this takes a few minutes)"
  "$ROOT/scripts/devnet/bring-up.sh"
fi

ENV_FILE="$CRISP_DIR/server/.env"
[ -f "$ENV_FILE" ] || fail "no $ENV_FILE — run 'pnpm dev:setup' in $CRISP_DIR first"
get_env() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d ' '; }

INTERFOLD_ADDRESS="$(get_env INTERFOLD_ADDRESS)"
FEE_TOKEN="$(get_env FEE_TOKEN_ADDRESS)"
CRISP_PROGRAM="$(get_env E3_PROGRAM_ADDRESS)"
[ -n "$INTERFOLD_ADDRESS" ] || fail "INTERFOLD_ADDRESS missing from $ENV_FILE"

# ─── 2. deploy ──────────────────────────────────────────────────────────────────────────────────

step "deploying the game (roster=$ROSTER, campaign=${CAMPAIGN_DURATION}s, ballot=${BALLOT_DURATION}s)"
DEPLOY_OUT="$(
  cd "$ROOT/contracts" &&
  INTERFOLD_ADDRESS="$INTERFOLD_ADDRESS" \
  CRISP_PROGRAM_ADDRESS="$CRISP_PROGRAM" \
  CAMPAIGN_DURATION="$CAMPAIGN_DURATION" \
  BALLOT_DURATION="$BALLOT_DURATION" \
  TALLY_GRACE="$TALLY_GRACE" \
  ROSTER_SIZE="$ROSTER" FINALISTS=2 MAX_MISSED_CHECKINS=0 ENTRY_FEE=0 \
  COMMITTEE_SIZE=0 PARAM_SET=0 \
  COMPUTE_PROVIDER_PARAMS="$COMPUTE_PROVIDER_PARAMS" \
  forge script script/DeployGame.s.sol:DeployGame \
    --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --broadcast 2>&1
)" || { echo "$DEPLOY_OUT" | tail -20; fail "deploy failed"; }

pick() { echo "$DEPLOY_OUT" | grep -Eo "$1 0x[0-9a-fA-F]{40}" | tail -1 | awk '{print $2}'; }
GAME="$(pick GAME)"; LIFE="$(pick LIFE)"; JURY="$(pick JURY)"
[ -n "$GAME" ] || { echo "$DEPLOY_OUT" | tail -20; fail "could not parse the deployed game address"; }
DEPLOY_BLOCK="$(cast block-number --rpc-url "$RPC" 2>/dev/null || echo 0)"

echo "  GAME $GAME"
echo "  LIFE $LIFE"
echo "  JURY $JURY"

# ─── 3. fund ────────────────────────────────────────────────────────────────────────────────────

step "funding the pot"
# Mint to the deployer and pull through fund(): tokens sent straight to the contract are invisible
# to `pot`, and every round's E3 fee is paid from it.
FUND=1000000000000 # 1,000,000 USDC (6dp)
send() { cast send "$@" --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --gas-limit 3000000 >/dev/null 2>&1; }
send "$FEE_TOKEN" "mint(address,uint256)" "$DEPLOYER_ADDR" "$FUND" || true
send "$FEE_TOKEN" "approve(address,uint256)" "$GAME" "$FUND"
send "$GAME" "fund(uint256)" "$FUND"

POT="$(cast call "$GAME" "pot()(uint256)" --rpc-url "$RPC" 2>/dev/null || echo 0)"
[ "${POT%% *}" != "0" ] || fail "pot is zero after funding — the game cannot pay for a round"
echo "  pot = $POT"

# ─── 4. configure the app ───────────────────────────────────────────────────────────────────────

step "writing app/.env"
[ -f "$ROOT/app/.env" ] && cp "$ROOT/app/.env" "$ROOT/app/.env.bak"

cat > "$ROOT/app/.env" <<EOF
# Generated by scripts/play.sh — regenerate rather than hand-edit.
NEXT_PUBLIC_GAME_ADDRESS=$GAME
NEXT_PUBLIC_LIFE_TOKEN_ADDRESS=$LIFE
NEXT_PUBLIC_JURY_TOKEN_ADDRESS=$JURY
NEXT_PUBLIC_GAME_DEPLOYMENT_BLOCK=$DEPLOY_BLOCK

NEXT_PUBLIC_INTERFOLD_ADDRESS=$INTERFOLD_ADDRESS
NEXT_PUBLIC_INTERFOLD_FEE_TOKEN_ADDRESS=$FEE_TOKEN
NEXT_PUBLIC_CRISP_PROGRAM_ADDRESS=$CRISP_PROGRAM
NEXT_PUBLIC_CRISP_SERVER_URL=$CRISP_SERVER

NEXT_PUBLIC_CHAIN_NAME=localhost
NEXT_PUBLIC_WEB3_ENDPOINT=$RPC
NEXT_PUBLIC_SECONDS_PER_BLOCK=1
EOF
echo "  app/.env written (previous copy at app/.env.bak)"

# ─── 5. serve ───────────────────────────────────────────────────────────────────────────────────

cat <<EOF

$(printf '\033[1m')Ready.$(printf '\033[0m')

  Game        $GAME
  Chain       $RPC  (chain id 31337)
  CRISP       $CRISP_SERVER
  Devnet logs /tmp/unravel-devnet/

  MetaMask: add the network above, then import accounts 6-9. Do NOT use accounts 0-5 —
  account 0 signs for the CRISP server and 1-5 are the ciphernodes; sharing them races nonces.

    #6  0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e
    #7  0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356
    #8  0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97
    #9  0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6

  In the app: Join with $ROSTER accounts -> Start the game -> campaign (${CAMPAIGN_DURATION}s) ->
  ballot (${BALLOT_DURATION}s) -> Settle round.

  The ballot stays unavailable until the committee key publishes, roughly 290s after Start.
  That is expected, not a hang.

  Tear down with: ./scripts/devnet/teardown.sh

EOF

if [ "$START_APP" = false ]; then
  step "not starting the app (--no-app). Start it with: cd app && bun dev"
  exit 0
fi

command -v bun >/dev/null 2>&1 || fail "bun is not installed — start the app manually with npm/yarn"
[ -d "$ROOT/app/node_modules" ] || (step "installing app dependencies" && cd "$ROOT/app" && bun install)

step "serving the app on http://localhost:$APP_PORT  (ctrl-c to stop; the devnet keeps running)"
cd "$ROOT/app" && exec bun dev --port "$APP_PORT"
