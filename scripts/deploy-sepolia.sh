#!/usr/bin/env bash
#
# Deploys UNRAVEL to Sepolia.
#
# Same four ordered steps as the local bootstrap — tokens, DAO + plugin, game, census link — but
# against the real Interfold deployment and the hosted CRISP coordination server. Defaults come from
# the-interfold-governance's Sepolia env, so only a key and an RPC are strictly required.
#
# Two differences from local that matter:
#
#   * The pot is funded with real testnet fee tokens, claimed from the Interfold faucet. Every
#     round's E3 fee comes out of the pot, so an unfunded game cannot open a round at all.
#   * `CAMPAIGN_DURATION` has a floor set by committee sortition and the DKG, and on a shared public
#     committee that floor is not the ~290s measured on a local devnet. The default here is
#     deliberately generous.
#
#   ./scripts/deploy-sepolia.sh              # deploy everything
#   ./scripts/deploy-sepolia.sh --dry-run    # simulate, broadcast nothing
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── Sepolia defaults (from the-interfold-governance/contracts/.env.example) ─────────────────────

RPC="${RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
INTERFOLD_ADDRESS="${INTERFOLD_ADDRESS:-0x13fA9Ecff929b4C86a2FCA4AEE91572EDee34486}"
CRISP_PROGRAM="${CRISP_PROGRAM_ADDRESS:-0x12f7a216aEaB6620dC3488754970b66c63ECdD2C}"
FEE_TOKEN="${FEE_TOKEN_ADDRESS:-0xb743cDE9fbC72Ba06654267d1970be72A4Ea1445}"
CRISP_SERVER="${CRISP_SERVER_URL:-https://private-crisp.theinterfold.com}"
# Testnet faucet. `faucet()` tops up FOLD and the fee token independently, and reverts with
# "You have enough tokens" when neither is below its threshold — so a repeat call is harmless but
# not silent.
FAUCET="${FAUCET_ADDRESS:-0x47Ef2F9764623Fd6154F389BA5Ccc54874F6EeD3}"
COMMITTEE_SIZE="${COMMITTEE_SIZE:-0}"
PARAM_SET="${PARAM_SET:-0}"
COMPUTE_PROVIDER_PARAMS="${COMPUTE_PROVIDER_PARAMS:-0x7b226e616d65223a225249534330222c22706172616c6c656c223a66616c73652c2262617463685f73697a65223a347d}"

# Round shape. Longer than local: a public committee is slower and less predictable than five
# ciphernodes on one machine, and players need real time to campaign.
TEAM_COUNT="${TEAM_COUNT:-4}"
MEMBERS_PER_TEAM="${MEMBERS_PER_TEAM:-3}"
MERGE_AT="${MERGE_AT:-6}"
FINALISTS="${FINALISTS:-2}"
CAMPAIGN_DURATION="${CAMPAIGN_DURATION:-72000}" # 20h
BALLOT_DURATION="${BALLOT_DURATION:-10800}"     # 3h
TALLY_GRACE="${TALLY_GRACE:-3600}"              # 1h
MAX_MISSED_CHECKINS="${MAX_MISSED_CHECKINS:-2}"
ENTRY_FEE="${ENTRY_FEE:-0}"

BROADCAST="--broadcast"
for arg in "$@"; do
  case "$arg" in
    --dry-run) BROADCAST="" ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m>>> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# ─── Preflight ──────────────────────────────────────────────────────────────────────────────────

for bin in cast forge; do
  command -v "$bin" >/dev/null 2>&1 || fail "$bin not found — install Foundry"
done

[ -n "${PRIVATE_KEY:-}" ] || fail "PRIVATE_KEY is not set.
       Use a throwaway deployer key. This script broadcasts real transactions:
         PRIVATE_KEY=0x... ./scripts/deploy-sepolia.sh"

DEPLOYER="$(cast wallet address --private-key "$PRIVATE_KEY")"
CHAIN_ID="$(cast chain-id --rpc-url "$RPC" 2>/dev/null || echo '')"
[ "$CHAIN_ID" = "11155111" ] || fail "chain id is '$CHAIN_ID', expected 11155111 (Sepolia) at $RPC"

BALANCE="$(cast balance "$DEPLOYER" --rpc-url "$RPC" 2>/dev/null || echo 0)"
step "deployer $DEPLOYER  ($(cast to-unit "$BALANCE" ether 2>/dev/null || echo '?') ETH)"
[ "$BALANCE" != "0" ] || fail "deployer has no Sepolia ETH"

# A wrong Interfold address is the failure that costs the most time to diagnose: `request` reverts
# with empty data and there is nothing in the revert to point at the cause.
cast code "$INTERFOLD_ADDRESS" --rpc-url "$RPC" 2>/dev/null | grep -q "^0x." ||
  fail "no contract at INTERFOLD_ADDRESS $INTERFOLD_ADDRESS on this chain"
cast code "$CRISP_PROGRAM" --rpc-url "$RPC" 2>/dev/null | grep -q "^0x." ||
  fail "no contract at CRISP_PROGRAM_ADDRESS $CRISP_PROGRAM on this chain"

step "targets"
echo "  interfold    $INTERFOLD_ADDRESS"
echo "  crispProgram $CRISP_PROGRAM"
echo "  feeToken     $FEE_TOKEN"
echo "  crispServer  $CRISP_SERVER"
[ -n "$BROADCAST" ] || step "DRY RUN — simulating, nothing will be broadcast"

pick() { echo "$1" | grep -Eo "$2 0x[0-9a-fA-F]{40}" | tail -1 | awk '{print $2}'; }
run_script() {
  local label="$1" root="$2" target="$3" env_prefix="$4" out
  if ! out="$(cd "$root" && eval "$env_prefix" forge script "$target" \
      --rpc-url "$RPC" --private-key "$PRIVATE_KEY" $BROADCAST 2>&1)"; then
    echo "$out" | tail -25
    fail "$label failed"
  fi
  echo "$out"
}

# ─── 1. tokens ──────────────────────────────────────────────────────────────────────────────────
# Deployed first because the plugin reads voting power from LIFE and needs its address at init.

step "deploying LIFE and JURY"
TOKENS_OUT="$(run_script "token deploy" "$ROOT/contracts" "script/DeployTokens.s.sol:DeployTokens" "")"
LIFE="$(pick "$TOKENS_OUT" LIFE)"; JURY="$(pick "$TOKENS_OUT" JURY)"
[ -n "$LIFE" ] && [ -n "$JURY" ] || { echo "$TOKENS_OUT" | tail -15; fail "could not parse token addresses"; }
echo "  LIFE $LIFE"
echo "  JURY $JURY"

# ─── 2. DAO + plugin ────────────────────────────────────────────────────────────────────────────
#
# Uses the same direct deploy as local rather than Aragon's DAOFactory/PluginRepoFactory. Those do
# exist on Sepolia, but their purpose is publishing a versioned plugin to a PluginRepo so arbitrary
# DAOs can install it — this game owns its own plugin instance and does not need to be installable.

step "deploying DAO and CRISP voting plugin"
PLUGIN_OUT="$(run_script "plugin deploy" "$ROOT/plugin" "script/DeployLocal.s.sol:DeployLocal" \
  "INTERFOLD_ADDRESS=$INTERFOLD_ADDRESS CRISP_PROGRAM_ADDRESS=$CRISP_PROGRAM VOTING_TOKEN_ADDRESS=$LIFE COMPUTE_PROVIDER_PARAMS=$COMPUTE_PROVIDER_PARAMS COMMITTEE_SIZE=$COMMITTEE_SIZE PARAM_SET=$PARAM_SET MIN_DURATION=$BALLOT_DURATION")"
DAO="$(pick "$PLUGIN_OUT" DAO)"; PLUGIN="$(pick "$PLUGIN_OUT" PLUGIN)"
[ -n "$PLUGIN" ] || { echo "$PLUGIN_OUT" | tail -25; fail "could not parse plugin address"; }
echo "  DAO    $DAO"
echo "  PLUGIN $PLUGIN"

# ─── 3. game ────────────────────────────────────────────────────────────────────────────────────

step "deploying the game ($TEAM_COUNT teams of $MEMBERS_PER_TEAM)"
GAME_OUT="$(run_script "game deploy" "$ROOT/contracts" "script/DeployGame.s.sol:DeployGame" \
  "LIFE_TOKEN_ADDRESS=$LIFE JURY_TOKEN_ADDRESS=$JURY CRISP_VOTING_PLUGIN_ADDRESS=$PLUGIN FEE_TOKEN_ADDRESS=$FEE_TOKEN CAMPAIGN_DURATION=$CAMPAIGN_DURATION BALLOT_DURATION=$BALLOT_DURATION TALLY_GRACE=$TALLY_GRACE TEAM_COUNT=$TEAM_COUNT MEMBERS_PER_TEAM=$MEMBERS_PER_TEAM MERGE_AT=$MERGE_AT FINALISTS=$FINALISTS MAX_MISSED_CHECKINS=$MAX_MISSED_CHECKINS ENTRY_FEE=$ENTRY_FEE")"
GAME="$(pick "$GAME_OUT" GAME)"
[ -n "$GAME" ] || { echo "$GAME_OUT" | tail -25; fail "could not parse the game address"; }
DEPLOY_BLOCK="$(cast block-number --rpc-url "$RPC" 2>/dev/null || echo 0)"
echo "  GAME $GAME (block $DEPLOY_BLOCK)"

if [ -z "$BROADCAST" ]; then
  step "dry run complete — nothing was deployed"
  exit 0
fi

# ─── 4. fund the pot ────────────────────────────────────────────────────────────────────────────
#
# Every round's E3 fee is paid from the pot, so a game with an empty pot cannot open a round. The
# faucet dispenses the fee token; amounts and decimals are read off the contract rather than assumed
# (the fee token is 6 decimals, FOLD is 18 — hardcoding either would be a silent factor-of-10^12 bug).

step "claiming fee tokens from the faucet"
if cast send "$FAUCET" "faucet()" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null 2>&1; then
  echo "  claimed"
else
  # Reverts once the deployer already holds enough, which is a success for our purposes.
  echo "  faucet declined (already funded, or dry — continuing)"
fi

FEE_BALANCE="$(cast call "$FEE_TOKEN" "balanceOf(address)(uint256)" "$DEPLOYER" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')"
FEE_BALANCE="${FEE_BALANCE:-0}"
if [ "$FEE_BALANCE" = "0" ]; then
  step "no fee tokens — the pot is unfunded and the game cannot open a round"
  echo "  claim manually, then fund:"
  echo "    cast send $FAUCET 'faucet()' --rpc-url $RPC --private-key \$PRIVATE_KEY"
  echo "    cast send $FEE_TOKEN 'approve(address,uint256)' $GAME <amount> --rpc-url $RPC --private-key \$PRIVATE_KEY"
  echo "    cast send $GAME 'fund(uint256)' <amount> --rpc-url $RPC --private-key \$PRIVATE_KEY"
else
  step "funding the pot with $FEE_BALANCE fee-token units"
  cast send "$FEE_TOKEN" "approve(address,uint256)" "$GAME" "$FEE_BALANCE" \
    --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null || fail "approve failed"
  cast send "$GAME" "fund(uint256)" "$FEE_BALANCE" \
    --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null || fail "fund failed"

  POT="$(cast call "$GAME" "pot()(uint256)" --rpc-url "$RPC" 2>/dev/null)"
  [ "${POT%% *}" != "0" ] || fail "pot is still zero after funding"
  echo "  pot = $POT"
fi

# ─── 5. census link ─────────────────────────────────────────────────────────────────────────────
#
# The coordination server resolves the electorate by asking the E3's requester, which is the plugin.
# Without this the roster is ignored and eligibility falls back to token-transfer-log discovery.

step "pointing the plugin's census at the game"
cast send "$PLUGIN" "setCensusProvider(address)" "$GAME" \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null || fail "setCensusProvider failed"

lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
PROVIDER="$(cast call "$PLUGIN" "censusProvider()(address)" --rpc-url "$RPC" 2>/dev/null)"
[ "$(lower "$PROVIDER")" = "$(lower "$GAME")" ] || fail "censusProvider is $PROVIDER, expected $GAME"
echo "  censusProvider = $PROVIDER"

# ─── Record ─────────────────────────────────────────────────────────────────────────────────────

cat > "$ROOT/.sepolia.env" <<EOF
# Generated by scripts/deploy-sepolia.sh — regenerate rather than hand-edit.
RPC_URL=$RPC
CRISP_SERVER_URL=$CRISP_SERVER
INTERFOLD_ADDRESS=$INTERFOLD_ADDRESS
FEE_TOKEN=$FEE_TOKEN
FAUCET=$FAUCET
CRISP_PROGRAM=$CRISP_PROGRAM
DAO=$DAO
PLUGIN=$PLUGIN
GAME=$GAME
LIFE=$LIFE
JURY=$JURY
DEPLOY_BLOCK=$DEPLOY_BLOCK
TEAM_COUNT=$TEAM_COUNT
MEMBERS_PER_TEAM=$MEMBERS_PER_TEAM
CAMPAIGN_DURATION=$CAMPAIGN_DURATION
BALLOT_DURATION=$BALLOT_DURATION
TALLY_GRACE=$TALLY_GRACE
EOF

cat <<EOF

$(printf '\033[1m')Deployed to Sepolia.$(printf '\033[0m')

  GAME    $GAME
  PLUGIN  $PLUGIN
  DAO     $DAO
  LIFE    $LIFE
  JURY    $JURY

  Recorded in .sepolia.env.

  $(printf '\033[1m')Still to do:$(printf '\033[0m')

  1. Point the frontend at it — copy .sepolia.env values into app/.env with
     NEXT_PUBLIC_CHAIN_NAME=sepolia, then: bun run app:dev

  2. Sanity-check the fee quote before inviting players. If the plugin's Interfold interface does
     not match this deployment, createProposal reverts with empty data and nothing in the revert
     explains why.

EOF
