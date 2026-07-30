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
#   * `CAMPAIGN_DURATION` still has a floor set by committee sortition and the DKG, but the Sepolia
#     committee is small and remote and forms faster than the local five-node setup. Measure it on
#     the first round rather than trusting the default.
#
# PRIVATE_KEY and any overrides can live in a gitignored .env at the repo root.
#
#   ./scripts/deploy-sepolia.sh              # deploy everything
#   ./scripts/deploy-sepolia.sh --dry-run    # rehearse on a local fork of Sepolia
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── .env ───────────────────────────────────────────────────────────────────────────────────────
#
# Loads PRIVATE_KEY and any overrides from a gitignored .env so the key does not have to be typed
# (or land in shell history) every run.
#
# Only sets variables that are not already in the environment, so precedence stays
# explicit > .env > built-in default. Sourcing the file outright would invert that and make an
# inline `RPC_URL=... ./deploy-sepolia.sh` silently do nothing.
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
if [ -f "$ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    # Tolerate `export KEY=`, surrounding quotes, and trailing comments.
    key="${key#export }"
    key="$(echo "$key" | tr -d '[:space:]')"
    val="${val%%#*}"
    val="$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")"
    [ -n "$key" ] || continue
    eval "current=\${$key:-}"
    [ -n "$current" ] || export "$key=$val"
  done < "$ENV_FILE"
fi

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

# Round shape.
#
# The Sepolia committee is three nodes on a remote server and forms considerably faster than the five
# local ciphernodes that produced the ~290s figure, so the campaign window does not need to be hours.
# It still has to comfortably exceed sortition plus the DKG, because the ballot opens the moment it
# ends and nothing can be encrypted before the committee key exists.
#
# The ballot window is sized for people, not for the committee: each ballot is 45-90s of proof
# generation in the browser, and a full roster proving sequentially is the real constraint.
TEAM_COUNT="${TEAM_COUNT:-4}"
MEMBERS_PER_TEAM="${MEMBERS_PER_TEAM:-3}"
MERGE_AT="${MERGE_AT:-6}"
FINALISTS="${FINALISTS:-2}"
CAMPAIGN_DURATION="${CAMPAIGN_DURATION:-900}" # 15m
BALLOT_DURATION="${BALLOT_DURATION:-1800}"    # 30m
TALLY_GRACE="${TALLY_GRACE:-600}"             # 10m
MAX_MISSED_CHECKINS="${MAX_MISSED_CHECKINS:-2}"
ENTRY_FEE="${ENTRY_FEE:-0}"

# A dry run forks Sepolia into a local anvil and deploys against that for real, rather than passing
# `forge script` without `--broadcast`.
#
# Script-by-script simulation cannot work here, and fails in a way that looks like a contract bug:
# each of the four steps feeds addresses to the next, but an unbroadcast `forge script` persists
# nothing, so every step re-simulates from the same deployer nonce and predicts the *same* addresses.
# Step 3 then calls `transferOwnership` on a LIFE token that does not exist, and reverts.
#
# Forking keeps state between steps, so the rehearsal exercises the real thing: the real Interfold and
# CRISP program bytecode, real fee-token decimals, the faucet, and — the point of rehearsing — whether
# the plugin's Interfold interface actually matches what is deployed.
DRY_RUN=0
BROADCAST="--broadcast"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
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
       Put it in $ENV_FILE (gitignored):
         cp .env.example .env    # then fill in PRIVATE_KEY
       or pass it inline:
         PRIVATE_KEY=0x... ./scripts/deploy-sepolia.sh
       Use a throwaway deployer key — this script broadcasts real transactions."

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

# ─── Fork, for a dry run ────────────────────────────────────────────────────────────────────────
#
# Deliberately not port 8545: a local devnet may well be running there, and this must not disturb it.
# Teardown kills by port for the same reason — `pkill -f anvil` matches on process name and would take
# down every chain on the machine, including other people's.
if [ "$DRY_RUN" = "1" ]; then
  command -v anvil >/dev/null 2>&1 || fail "anvil not found — install Foundry"
  FORK_PORT="${FORK_PORT:-8555}"
  lsof -nP -i:"$FORK_PORT" >/dev/null 2>&1 &&
    fail "port $FORK_PORT is in use — set FORK_PORT to something free"

  step "DRY RUN — forking Sepolia into a local anvil on port $FORK_PORT"
  # Enough funded accounts to fill the lobby in the rehearsal at the end.
  FORK_ACCOUNTS=$((TEAM_COUNT * MEMBERS_PER_TEAM))
  [ "$FORK_ACCOUNTS" -ge 10 ] || FORK_ACCOUNTS=10
  anvil --fork-url "$RPC" --port "$FORK_PORT" --accounts "$FORK_ACCOUNTS" --silent >/dev/null 2>&1 &
  FORK_PID=$!
  # Kill only this anvil, by pid, and only if it is still ours to kill.
  trap 'kill "$FORK_PID" 2>/dev/null || true' EXIT

  RPC="http://127.0.0.1:$FORK_PORT"
  for _ in $(seq 1 30); do
    [ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null || echo '')" = "11155111" ] && break
    sleep 1
  done
  [ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null || echo '')" = "11155111" ] ||
    fail "fork did not come up at $RPC"
  echo "  forked at block $(cast block-number --rpc-url "$RPC")"
fi

pick() { echo "$1" | grep -Eo "$2 0x[0-9a-fA-F]{40}" | tail -1 | awk '{print $2}'; }
run_script() {
  local label="$1" root="$2" target="$3" env_prefix="$4" out
  if ! out="$(cd "$root" && eval "$env_prefix" forge script "$target" \
      --rpc-url "$RPC" --private-key "$PRIVATE_KEY" $BROADCAST 2>&1)"; then
    # stderr, not stdout: stdout is captured by the caller's command substitution, so a plain echo
    # here would swallow the only diagnostic the failure produces.
    echo "$out" | tail -25 >&2
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
  echo "  faucet declined (deployer already holds enough — continuing)"
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

# ─── 6. rehearse a round (dry run only) ─────────────────────────────────────────────────────────
#
# The check worth having. `startGame` opens the first round, which routes through the plugin into the
# real Interfold `request` — so this is where an ABI mismatch surfaces, and it surfaces as a revert
# with empty data that explains nothing. Finding that on a fork costs nothing; finding it after a live
# deploy means redeploying.
if [ "$DRY_RUN" = "1" ]; then
  NEED=$((TEAM_COUNT * MEMBERS_PER_TEAM))
  step "rehearsing: filling the lobby with $NEED players and opening a round"

  MNEMONIC="test test test test test test test test test test test junk"
  i=0
  while [ "$i" -lt "$NEED" ]; do
    KEY="$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index "$i" 2>/dev/null)"
    TEAM=$(((i % TEAM_COUNT) + 1))
    # A fixed gas limit: estimation races the ERC20Votes checkpoint write, whose cost is
    # state-dependent, and an underestimate surfaces as an opaque out-of-gas.
    cast send "$GAME" "join(uint8)" "$TEAM" --gas-limit 400000 \
      --rpc-url "$RPC" --private-key "$KEY" >/dev/null 2>&1 || fail "join failed for player $i"
    i=$((i + 1))
  done
  echo "  joined $(cast call "$GAME" 'aliveCount()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"

  if ! OUT="$(cast send "$GAME" "startGame()" --gas-limit 3000000 \
      --rpc-url "$RPC" --private-key "$PRIVATE_KEY" 2>&1)"; then
    echo "$OUT" | tail -20 >&2
    fail "startGame reverted — the round could not be opened against the real Interfold.
       An empty revert here almost always means the plugin's IInterfold does not match the
       deployment at $INTERFOLD_ADDRESS (a single extra struct field changes the selector)."
  fi
  # `cast send` exits 0 on a reverted transaction, so the receipt status has to be read explicitly.
  echo "$OUT" | grep -q "status  *1" || { echo "$OUT" | tail -20 >&2; fail "startGame transaction reverted"; }

  # Nine fields, and the order matters: `e3Id` is third, after `kind` and `proposalId`. Decoding a
  # shorter signature and taking the first line silently reads the round *kind* instead.
  ROUND_SIG='getRound(uint256)(uint8,uint256,uint256,uint64,uint64,uint64,bool,address,uint8)'
  E3="$(cast call "$GAME" "$ROUND_SIG" 0 --rpc-url "$RPC" 2>/dev/null |
    sed -n '3p' | sed 's/ \[.*\]//')"
  echo "  round 0 opened, e3Id $E3 — the Interfold interface matches"
  # An e3Id is only meaningful if Interfold agrees it exists; a misread offset would print a
  # plausible-looking number that belongs to no E3.
  cast call "$INTERFOLD_ADDRESS" "getE3(uint256)" "$E3" --rpc-url "$RPC" >/dev/null 2>&1 ||
    fail "the game recorded e3Id $E3 but Interfold has no such E3 — the request return was misread"
  echo "  Interfold confirms E3 $E3 exists"

  step "dry run complete — nothing was deployed to Sepolia"
  echo "  Everything above happened on the fork and is now discarded."
  echo "  Re-run without --dry-run to deploy for real."
  exit 0
fi

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

step "writing app/.env"
[ -f "$ROOT/app/.env" ] && cp "$ROOT/app/.env" "$ROOT/app/.env.bak"

cat > "$ROOT/app/.env" <<EOF
# Generated by scripts/deploy-sepolia.sh — regenerate rather than hand-edit.
NEXT_PUBLIC_GAME_ADDRESS=$GAME
NEXT_PUBLIC_LIFE_TOKEN_ADDRESS=$LIFE
NEXT_PUBLIC_JURY_TOKEN_ADDRESS=$JURY
NEXT_PUBLIC_GAME_DEPLOYMENT_BLOCK=$DEPLOY_BLOCK

NEXT_PUBLIC_INTERFOLD_ADDRESS=$INTERFOLD_ADDRESS
NEXT_PUBLIC_INTERFOLD_FEE_TOKEN_ADDRESS=$FEE_TOKEN
NEXT_PUBLIC_CRISP_PROGRAM_ADDRESS=$CRISP_PROGRAM
NEXT_PUBLIC_CRISP_VOTING_PLUGIN_ADDRESS=$PLUGIN
NEXT_PUBLIC_DAO_ADDRESS=$DAO
NEXT_PUBLIC_CRISP_SERVER_URL=$CRISP_SERVER

NEXT_PUBLIC_CHAIN_NAME=sepolia
NEXT_PUBLIC_WEB3_ENDPOINT=$RPC
NEXT_PUBLIC_SECONDS_PER_BLOCK=12
EOF
echo "  app/.env written (previous copy at app/.env.bak)"

cat <<EOF

$(printf '\033[1m')Deployed to Sepolia.$(printf '\033[0m')

  GAME    $GAME
  PLUGIN  $PLUGIN
  DAO     $DAO
  LIFE    $LIFE
  JURY    $JURY

  Recorded in .sepolia.env.

  $(printf '\033[1m')Still to do:$(printf '\033[0m')

  1. bun run app:dev   — app/.env already points at this deployment.

  2. Import the deployer (or any funded key) into MetaMask on Sepolia, join $((TEAM_COUNT * MEMBERS_PER_TEAM))
     players across $TEAM_COUNT teams, then Start. Players need Sepolia ETH for gas but no fee tokens:
     the E3 fee comes from the pot.

  3. The campaign window is ${CAMPAIGN_DURATION}s. The ballot cannot open before the committee
     publishes its key, so watch that the key lands inside that window on the first round and
     raise CAMPAIGN_DURATION if it does not.

EOF
