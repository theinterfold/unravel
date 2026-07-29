#!/usr/bin/env bash
#
# Drives one real elimination round against a local CRISP devnet.
#
# This is the test the mocked Foundry suite cannot be: it exercises the parts that only exist
# outside the contract — that the CRISP coordination server resolves eligibility by calling
# getCensus() on the game, that a committee actually forms and publishes a key inside the campaign
# window, that ballots prove and broadcast, and that the decrypted tally comes back in the shape
# settleRound() expects.
#
# Prerequisites: `pnpm dev:up` running in examples/CRISP (anvil, ciphernodes, program server,
# coordination server).
#
# Usage: run-round.sh [roster_size]

set -euo pipefail

ROSTER="${1:-4}"
RPC="${RPC_URL:-http://127.0.0.1:8545}"
CRISP_SERVER="${CRISP_SERVER_URL:-http://127.0.0.1:4000}"

# The campaign window has to outlast committee sortition and the DKG, because the ballot window
# opens the moment it ends — a voter cannot encrypt anything before the committee key exists.
#
# Measured on this devnet (5 ciphernodes, insecure-512, mock verifiers, sharing a machine with
# another proving workload): E3Requested -> CommitteePublished took ~287s. A 180s campaign window
# put the key 107s *after* the ballot opened, and every ballot failed. 480s leaves real headroom;
# treat ~290s as the floor to measure against rather than a constant to trust, since it moves with
# hardware, committee size and preset.
CAMPAIGN_DURATION="${CAMPAIGN_DURATION:-480}"
BALLOT_DURATION="${BALLOT_DURATION:-240}"
TALLY_GRACE="${TALLY_GRACE:-120}"

# Deterministic anvil accounts (mnemonic "test test test ...").
#
# Account roles on a CRISP devnet are NOT free to choose:
#   account 0    — the coordination server's signer (it broadcasts every ballot on-chain)
#   accounts 1-5 — the five ciphernodes (they transact throughout the DKG)
# Using either as a player races nonces against a process that is actively sending transactions,
# which shows up as random "nonce too low" failures mid-round. Players therefore start at account 6,
# which caps a default 10-account anvil at a four-player roster.
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PLAYER_KEYS=(
  0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e # account 6
  0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356 # account 7
  0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97 # account 8
  0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6 # account 9
)
# Settlement is permissionless, so it runs from a player account rather than the server's signer —
# by then the server is mid-tally and a shared nonce would be a real collision.
SETTLE_KEY="${PLAYER_KEYS[3]}"

step() { printf '\n\033[1m>>> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# Sends a transaction and surfaces the revert instead of hiding it. `cast send`'s useful output is
# on stderr, so a bare `>/dev/null` turns a reverted transaction into a silent no-op — which is
# exactly how a short roster reaches startGame and fails there instead of here.
# Override the signing key for one call with `KEY=0x... send ...`.
# A fixed generous gas limit rather than estimation. `cast send` estimates against current state,
# but with a 1s block time the estimate for one join is taken while the previous is still pending —
# and ERC20Votes checkpoint gas is state-dependent: two mints in the same block overwrite the shared
# total-supply checkpoint (cheap), in different blocks they append a new slot (~20k more). The
# estimate sees the cheap path, execution takes the expensive one, and the join reverts out-of-gas
# having simulated perfectly. Anvil accounts have 10000 ETH; over-reserving costs nothing.
GAS_LIMIT="${GAS_LIMIT:-3000000}"

send() {
  local label="$1" target="$2" sig="$3"
  shift 3
  local key="${KEY:-$DEPLOYER_KEY}"
  local out
  if ! out="$(cast send "$target" "$sig" "$@" --rpc-url "$RPC" --private-key "$key" --gas-limit "$GAS_LIMIT" 2>&1)"; then
    printf '\033[31m  %s failed:\033[0m\n%s\n' "$label" "$(echo "$out" | grep -v 'nightly build' | tail -3)" >&2
    return 1
  fi

  # `cast send` exits 0 even when the transaction reverts, so the receipt status has to be read
  # explicitly — otherwise a reverted call looks exactly like a successful one.
  local status
  status="$(echo "$out" | grep -iE '^status' | head -1)"
  case "$status" in
    *"0 (failed)"* | *"0x0"*)
      printf '\033[31m  %s reverted on-chain\033[0m\n' "$label" >&2
      return 1
      ;;
  esac
  return 0
}

# ─── Resolve the devnet deployment ──────────────────────────────────────────────────────────────

CRISP_DIR="${CRISP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../interfold/.claude/worktrees/survival-game/examples/CRISP" && pwd)}"
ENV_FILE="$CRISP_DIR/server/.env"
[ -f "$ENV_FILE" ] || fail "no $ENV_FILE — has 'pnpm dev:setup' run?"

get_env() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d ' '; }

INTERFOLD_ADDRESS="$(get_env INTERFOLD_ADDRESS)"
FEE_TOKEN="$(get_env FEE_TOKEN_ADDRESS)"
CRISP_PROGRAM="$(get_env E3_PROGRAM_ADDRESS)"

[ -n "$INTERFOLD_ADDRESS" ] || fail "INTERFOLD_ADDRESS missing"
step "devnet: interfold=$INTERFOLD_ADDRESS feeToken=$FEE_TOKEN crispProgram=$CRISP_PROGRAM"

cast block-number --rpc-url "$RPC" >/dev/null 2>&1 || fail "no chain at $RPC — is 'pnpm dev:up' running?"
curl -sf "$CRISP_SERVER/health" >/dev/null 2>&1 || echo "note: $CRISP_SERVER/health not responding; continuing"

# ─── Deploy the game ────────────────────────────────────────────────────────────────────────────
#
# Durations are short but not arbitrary: the campaign window has to outlast committee sortition and
# the DKG, because the ballot window opens at the end of it. This is the R1 floor the plan flagged
# as unmeasured — if the committee key is not published by the time the ballot opens, this run is
# what tells us so.

step "deploying game (roster=$ROSTER)"
CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../contracts" && pwd)"

DEPLOY_OUT="$(
  cd "$CONTRACTS_DIR" &&
  INTERFOLD_ADDRESS="$INTERFOLD_ADDRESS" \
  CRISP_PROGRAM_ADDRESS="$CRISP_PROGRAM" \
  CAMPAIGN_DURATION="$CAMPAIGN_DURATION" \
  BALLOT_DURATION="$BALLOT_DURATION" \
  TALLY_GRACE="$TALLY_GRACE" \
  ROSTER_SIZE="$ROSTER" \
  FINALISTS=2 \
  MAX_MISSED_CHECKINS=0 \
  ENTRY_FEE=0 \
  COMMITTEE_SIZE=0 \
  PARAM_SET=0 \
  COMPUTE_PROVIDER_PARAMS=0x7b226e616d65223a225249534330222c22706172616c6c656c223a66616c73652c2262617463685f73697a65223a347d \
  forge script script/DeployGame.s.sol:DeployGame \
    --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --broadcast 2>&1
)" || { echo "$DEPLOY_OUT"; fail "deploy failed"; }

GAME="$(echo "$DEPLOY_OUT" | grep -Eo 'GAME 0x[0-9a-fA-F]{40}' | tail -1 | awk '{print $2}')"
[ -n "$GAME" ] || { echo "$DEPLOY_OUT"; fail "could not parse game address"; }
step "game deployed at $GAME"

# ─── Fund the pot ───────────────────────────────────────────────────────────────────────────────
# Entry is free, so the pot has to be seeded directly or the first round cannot pay its E3 fee.

step "funding the pot"
# Mint to the *deployer*, not the game: `fund()` pulls with transferFrom and credits `pot`, whereas
# tokens sent straight to the contract are invisible to it. The fee token is USDC-like (6 dp) with
# a public mint on this devnet.
FUND_AMOUNT=1000000000000 # 1,000,000 USDC
DEPLOYER_ADDR="$(cast wallet address --private-key "$DEPLOYER_KEY")"

send "mint fee tokens" "$FEE_TOKEN" "mint(address,uint256)" "$DEPLOYER_ADDR" "$FUND_AMOUNT"
send "approve game" "$FEE_TOKEN" "approve(address,uint256)" "$GAME" "$FUND_AMOUNT"
send "fund pot" "$GAME" "fund(uint256)" "$FUND_AMOUNT"

POT="$(cast call "$GAME" "pot()(uint256)" --rpc-url "$RPC" 2>/dev/null)"
[ "${POT%% *}" != "0" ] || fail "pot is still zero after funding"
step "pot = $POT"

# ─── Fill the lobby ─────────────────────────────────────────────────────────────────────────────
#
# Joins are verified rather than fired and forgotten: a silently dropped join leaves the roster
# short and the failure only surfaces later as RosterIncomplete from startGame, which is a much
# harder thing to read.

step "joining $ROSTER players"
for ((i = 0; i < ROSTER; i++)); do
  KEY="${PLAYER_KEYS[$i]}"
  ADDR="$(cast wallet address --private-key "$KEY")"

  if [ "$(cast call "$GAME" "isPlayer(address)(bool)" "$ADDR" --rpc-url "$RPC" 2>/dev/null)" = "true" ]; then
    echo "  $ADDR already joined"
    continue
  fi

  KEY="$KEY" send "join $ADDR" "$GAME" "join()" ||
    { sleep 2; KEY="$KEY" send "join $ADDR (retry)" "$GAME" "join()"; }

  [ "$(cast call "$GAME" "isPlayer(address)(bool)" "$ADDR" --rpc-url "$RPC" 2>/dev/null)" = "true" ] ||
    fail "$ADDR did not join"
done

ALIVE="$(cast call "$GAME" "aliveCount()(uint256)" --rpc-url "$RPC" 2>/dev/null)"
[ "${ALIVE%% *}" = "$ROSTER" ] || fail "roster is $ALIVE, expected $ROSTER"
step "roster full: $ALIVE"

step "starting the game (this requests the E3)"
START_TS="$(date +%s)"
send "startGame" "$GAME" "startGame()" || fail "startGame reverted"

E3_ID="$(cast call "$GAME" "getRound(uint256)(uint256,uint64,uint64,uint64,bool,address)" 0 --rpc-url "$RPC" | head -1)"
step "round 0 -> e3Id=$E3_ID"

# ─── The census hook ────────────────────────────────────────────────────────────────────────────

step "getCensus($E3_ID) as the CRISP server will call it"
cast call "$GAME" "getCensus(uint256)(address[])" "$E3_ID" --rpc-url "$RPC"

# ─── Wait for the committee ─────────────────────────────────────────────────────────────────────

step "waiting for the committee key (measuring the campaign-window floor)"
KEY_READY=""
# Round state is a POST to /state/lite with a JSON body — not a GET on a path. Guessing the latter
# returns an empty body forever, which is indistinguishable from "the committee never formed" and
# will happily report a healthy devnet as a failure.
for _ in $(seq 1 120); do
  STATE="$(curl -s -X POST "$CRISP_SERVER/state/lite" \
    -H 'Content-Type: application/json' -d "{\"round_id\":$E3_ID}" 2>/dev/null || echo '')"
  # Check positively for a populated key. Testing "not the empty-array pattern" also passes on the
  # server's plain-text error bodies ("Failed to get E3 state"), which reports a key as ready one
  # second in and makes the whole measurement meaningless.
  if echo "$STATE" | grep -qE '"committee_public_key":\[[0-9]'; then
    KEY_READY="$(( $(date +%s) - START_TS ))"
    break
  fi
  sleep 5
done

[ -n "$KEY_READY" ] || fail "committee key never published — the campaign window is too short, or the committee did not form"
step "committee key published after ${KEY_READY}s (campaign window is ${CAMPAIGN_DURATION}s)"

echo "$STATE" | head -c 400; echo

# ─── Cast ballots ───────────────────────────────────────────────────────────────────────────────

step "waiting for the ballot window to open"
until [ "$(date +%s)" -ge "$((START_TS + CAMPAIGN_DURATION))" ]; do sleep 5; done

step "casting $ROSTER ballots (everyone votes for candidate 0)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for ((i = 0; i < ROSTER; i++)); do
  node "$SCRIPT_DIR/cast-ballot.mjs" --e3 "$E3_ID" --key "${PLAYER_KEYS[$i]}" --candidate 0 --server "$CRISP_SERVER" ||
    echo "  ballot $i failed"
done

# ─── Settle ─────────────────────────────────────────────────────────────────────────────────────

step "waiting for the ballot window to close and the tally to land"
until [ "$(date +%s)" -ge "$((START_TS + CAMPAIGN_DURATION + BALLOT_DURATION + TALLY_GRACE))" ]; do sleep 10; done

step "tally"
cast call "$CRISP_PROGRAM" "decodeTally(uint256)(uint256[])" "$E3_ID" --rpc-url "$RPC" || echo "  tally not published"

step "settling"
KEY="$SETTLE_KEY" send "settleRound" "$GAME" "settleRound()" || fail "settleRound reverted"

step "result"
echo "alive: $(cast call "$GAME" "aliveCount()(uint256)" --rpc-url "$RPC")"
echo "jurors: $(cast call "$GAME" "jurors()(address[])" --rpc-url "$RPC")"
cast call "$GAME" "getRound(uint256)(uint256,uint64,uint64,uint64,bool,address)" 0 --rpc-url "$RPC"

step "done — committee key took ${KEY_READY}s"
