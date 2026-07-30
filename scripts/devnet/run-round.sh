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

# Team sizes and the server URL are read from .devnet.env below; these are only fallbacks for a
# hand-driven run. Anything derived from them has to be computed *after* that file is sourced.
RPC="${RPC_URL:-http://127.0.0.1:8545}"
# The campaign window has to outlast committee sortition and the DKG, because the ballot window
# opens the moment it ends — a voter cannot encrypt anything before the committee key exists.
#
# Measured on this devnet (5 ciphernodes, insecure-512, mock verifiers, sharing a machine with
# another proving workload): E3Requested -> CommitteePublished took ~287s. A 180s campaign window
# put the key 107s *after* the ballot opened, and every ballot failed. 480s leaves real headroom;
# treat ~290s as the floor to measure against rather than a constant to trust, since it moves with
# hardware, committee size and preset.
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

# ─── Load the deployment ────────────────────────────────────────────────────────────────────────
#
# Addresses come from .devnet.env, written by scripts/play.sh when it deploys. This script used to
# deploy the game itself, which meant two places had to agree on deployment order — and they stopped
# agreeing the moment tokens and the plugin had to be deployed first. One writer, many readers.

STATE="${DEVNET_ENV:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.devnet.env}"
[ -f "$STATE" ] || fail "no $STATE — deploy first with: bun run play:headless"
# shellcheck disable=SC1090
. "$STATE"

for v in GAME LIFE JURY PLUGIN FEE_TOKEN CRISP_PROGRAM RPC_URL; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || fail "$v missing from $STATE — re-run: bun run play:headless"
done
RPC="$RPC_URL"

# Derived after sourcing, so the recorded deployment wins over any stale default.
TEAM_COUNT="${TEAM_COUNT:-2}"
MEMBERS_PER_TEAM="${MEMBERS_PER_TEAM:-2}"
ROSTER=$((TEAM_COUNT * MEMBERS_PER_TEAM))
CRISP_SERVER="${CRISP_SERVER_URL:-http://127.0.0.1:4000}"
CAMPAIGN_DURATION="${CAMPAIGN_DURATION:-480}"
BALLOT_DURATION="${BALLOT_DURATION:-240}"
TALLY_GRACE="${TALLY_GRACE:-120}"

cast block-number --rpc-url "$RPC" >/dev/null 2>&1 || fail "no chain at $RPC — run: bun run devnet:up"

step "game=$GAME plugin=$PLUGIN"
POT="$(cast call "$GAME" "pot()(uint256)" --rpc-url "$RPC" 2>/dev/null)"
[ "${POT%% *}" != "0" ] || fail "pot is zero — the game cannot pay for a round"
step "pot = $POT"


# ─── Fill the lobby ─────────────────────────────────────────────────────────────────────────────
#
# Joins are verified rather than fired and forgotten: a silently dropped join leaves the roster
# short and the failure only surfaces later as RosterIncomplete from startGame, which is a much
# harder thing to read.

step "joining $ROSTER players across $TEAM_COUNT teams"
for ((i = 0; i < ROSTER; i++)); do
  KEY="${PLAYER_KEYS[$i]}"
  ADDR="$(cast wallet address --private-key "$KEY")"

  if [ "$(cast call "$GAME" "isPlayer(address)(bool)" "$ADDR" --rpc-url "$RPC" 2>/dev/null)" = "true" ]; then
    echo "  $ADDR already joined"
    continue
  fi

  # Players are spread across teams in order, matching the contract's lobby rule.
  TEAM=$(( i / MEMBERS_PER_TEAM + 1 ))
  KEY="$KEY" send "join $ADDR (team $TEAM)" "$GAME" "join(uint8)" "$TEAM" ||
    { sleep 2; KEY="$KEY" send "join $ADDR (retry)" "$GAME" "join(uint8)" "$TEAM"; }

  [ "$(cast call "$GAME" "isPlayer(address)(bool)" "$ADDR" --rpc-url "$RPC" 2>/dev/null)" = "true" ] ||
    fail "$ADDR did not join"
done

ALIVE="$(cast call "$GAME" "aliveCount()(uint256)" --rpc-url "$RPC" 2>/dev/null)"
[ "${ALIVE%% *}" = "$ROSTER" ] || fail "roster is $ALIVE, expected $ROSTER ($TEAM_COUNT x $MEMBERS_PER_TEAM)"
step "roster full: $ALIVE"

step "starting the game (this requests the E3)"
START_TS="$(date +%s)"
send "startGame" "$GAME" "startGame()" || fail "startGame reverted"

round_field() { cast call "$GAME" 'getRound(uint256)(uint8,uint256,uint256,uint64,uint64,uint64,bool,address,uint8)' "$1" --rpc-url "$RPC" 2>/dev/null | sed 's/ \[.*\]//' | sed -n "$(( $2 + 1 ))p"; }
E3_ID="$(round_field 0 2)"
KIND="$(round_field 0 0)"
step "round 0 -> kind=$KIND (0=tribal) e3Id=$E3_ID"

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

# A tribal round condemns a team without eliminating anyone, so the elimination only happens in the
# council round that follows. Reporting "done" here would claim a result the game has not reached.
OUTCOME="$(round_field 0 7)"
TARGET="$(round_field 0 8)"
if [ "$KIND" = "0" ] && [ "$OUTCOME" = "0x0000000000000000000000000000000000000000" ] && [ "$TARGET" != "0" ]; then
  step "team $TARGET condemned — a council round is required to eliminate anyone"
  echo "  open it with: cast send $GAME 'openRound()' --rpc-url $RPC --private-key <key>"
  echo "  only team $TARGET may vote in it; run this script's ballot step with their keys"
fi

step "result"
echo "alive: $(cast call "$GAME" "aliveCount()(uint256)" --rpc-url "$RPC")"
echo "jurors: $(cast call "$GAME" "jurors()(address[])" --rpc-url "$RPC")"
cast call "$GAME" 'getRound(uint256)(uint8,uint256,uint256,uint64,uint64,uint64,bool,address,uint8)' 0 --rpc-url "$RPC"

step "done — committee key took ${KEY_READY}s"
