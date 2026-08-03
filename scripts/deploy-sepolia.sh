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
# A floor, not a ceiling — teams may grow to MAX_TEAM_SIZE whatever this says. MEMBERS_PER_TEAM is
# the old name for it and is still honoured.
MIN_MEMBERS_PER_TEAM="${MIN_MEMBERS_PER_TEAM:-${MEMBERS_PER_TEAM:-2}}"
# The circuit's MAX_OPTIONS: a council ballot has one option per team member.
MAX_TEAM_SIZE=10
# The lobby floor. Well below a full lobby on purpose: waiting for every seat makes the game hostage
# to the slowest joiner. Must exceed MERGE_AT for tribal rounds to happen at all.
CAPACITY=$((TEAM_COUNT * MAX_TEAM_SIZE))
# The smallest legal start: every team at its floor. Deriving it means a small roster works out of
# the box — a fixed default silently exceeded the lobby for any roster below it.
MIN_PLAYERS="${MIN_PLAYERS:-$((TEAM_COUNT * MIN_MEMBERS_PER_TEAM))}"
MERGE_AT="${MERGE_AT:-6}"
FINALISTS="${FINALISTS:-2}"
# Shape: the ballot is roughly three times the campaign, and that asymmetry is deliberate.
#
# The campaign window has two jobs — people talking, and sortition plus the DKG finishing — and the
# second sets a hard floor on it. Below that floor the ballot opens against a committee key that does
# not exist yet, so shortening the campaign does not buy voting time, it destroys it.
#
# The ballot window has one job and it is slow: every voter spends 45-90s generating a proof, in a
# browser, and anyone driving several wallets does it sequentially. That is what needs room.
#
# A longer input window does raise the E3 fee — Interfold prices availability per node per second —
# but only slightly: at the Minimum committee it is about 150 fee-token units a second, so an extra
# fifteen minutes costs roughly 1% of a ~14-token round.
CAMPAIGN_DURATION="${CAMPAIGN_DURATION:-900}"  # 15m — floored by sortition + DKG, not by taste
BALLOT_DURATION="${BALLOT_DURATION:-2700}"     # 45m — floored by browser proving, per voter
TALLY_GRACE="${TALLY_GRACE:-600}"              # 10m
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
if [ "$CHAIN_ID" != "11155111" ]; then
  # An empty chain id means the endpoint did not answer at all, and `cast` discards the reason. Ask
  # again with curl so the RPC's own words reach the user: a rate limit, an expired key and a typo in
  # the URL are three very different problems that otherwise look identical here.
  REASON="$(curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$RPC" 2>/dev/null |
    sed -n 's/.*"message":"\([^"]*\)".*/\1/p')"
  fail "no usable Sepolia RPC at $RPC
       ${REASON:+the endpoint said: $REASON
       }chain id came back '${CHAIN_ID:-<no response>}', expected 11155111.
       Override for one run:
         RPC_URL=https://ethereum-sepolia-rpc.publicnode.com bun run deploy:sepolia
       or change RPC_URL in $ENV_FILE."
fi

BALANCE="$(cast balance "$DEPLOYER" --rpc-url "$RPC" 2>/dev/null || echo 0)"
step "deployer $DEPLOYER  ($(cast to-unit "$BALANCE" ether 2>/dev/null || echo '?') ETH)"
[ "$BALANCE" != "0" ] || fail "deployer has no Sepolia ETH"

# A wrong Interfold address is the failure that costs the most time to diagnose: `request` reverts
# with empty data and there is nothing in the revert to point at the cause.
cast code "$INTERFOLD_ADDRESS" --rpc-url "$RPC" 2>/dev/null | grep -q "^0x." ||
  fail "no contract at INTERFOLD_ADDRESS $INTERFOLD_ADDRESS on this chain"
cast code "$CRISP_PROGRAM" --rpc-url "$RPC" 2>/dev/null | grep -q "^0x." ||
  fail "no contract at CRISP_PROGRAM_ADDRESS $CRISP_PROGRAM on this chain"

# ─── Round shape ────────────────────────────────────────────────────────────────────────────────
#
# Mirrors `SurvivalGame`'s constructor checks. The contract is the authority, but it reverts with a
# bare `InvalidConfig()` that names no field — so the same rules are restated here purely to say
# which knob is wrong, and after a deploy has already spent gas on tokens and the plugin.
cfg_fail() { fail "round shape rejected: $1
       team_count=$TEAM_COUNT min_members_per_team=$MIN_MEMBERS_PER_TEAM (capacity $CAPACITY)
       min_players=$MIN_PLAYERS merge_at=$MERGE_AT finalists=$FINALISTS"; }

[ "$FINALISTS" -ge 2 ] || cfg_fail "FINALISTS must be at least 2 — a jury needs two names to choose between"
[ "$TEAM_COUNT" -ge 2 ] || cfg_fail "TEAM_COUNT must be at least 2"
[ "$TEAM_COUNT" -le 10 ] || cfg_fail "TEAM_COUNT must be at most 10 (the circuit's MAX_OPTIONS)"
[ "$MIN_MEMBERS_PER_TEAM" -ge 1 ] || cfg_fail "MIN_MEMBERS_PER_TEAM must be at least 1"
[ "$MIN_MEMBERS_PER_TEAM" -le "$MAX_TEAM_SIZE" ] || cfg_fail "MIN_MEMBERS_PER_TEAM must be at most $MAX_TEAM_SIZE (the circuit's MAX_OPTIONS)"
[ "$MERGE_AT" -le 10 ] || cfg_fail "MERGE_AT must be at most 10"
[ "$MERGE_AT" -ge "$FINALISTS" ] || cfg_fail "MERGE_AT must be at least FINALISTS"
[ "$CAPACITY" -gt "$FINALISTS" ] || cfg_fail "lobby capacity must exceed FINALISTS, or the game starts already over"
[ "$MIN_PLAYERS" -gt "$FINALISTS" ] || cfg_fail "MIN_PLAYERS must exceed FINALISTS, or the game starts already over"
[ "$MIN_PLAYERS" -le "$CAPACITY" ] || cfg_fail "MIN_PLAYERS ($MIN_PLAYERS) is above lobby capacity ($CAPACITY) — a floor that can never be reached"
[ "$MIN_PLAYERS" -ge $((TEAM_COUNT * MIN_MEMBERS_PER_TEAM)) ] || cfg_fail "MIN_PLAYERS ($MIN_PLAYERS) is below TEAM_COUNT x MIN_MEMBERS_PER_TEAM ($((TEAM_COUNT * MIN_MEMBERS_PER_TEAM))) — the lobby could reach the floor while a team is still short"

# Not a contract rule, but the thing most likely to disappoint: `_nextKind` checks the merge before
# team count, so a floor at or below MERGE_AT means the game is post-merge from round one and no
# tribal or council round ever happens.
if [ "$MIN_PLAYERS" -le "$MERGE_AT" ]; then
  printf '\033[33m>>> note: MIN_PLAYERS (%s) <= MERGE_AT (%s) — tribes dissolve immediately, every round is an individual vote\033[0m\n' \
    "$MIN_PLAYERS" "$MERGE_AT"
fi

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
  FORK_ACCOUNTS=$MIN_PLAYERS
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

step "deploying the game ($TEAM_COUNT teams, min $MIN_MEMBERS_PER_TEAM each, starts at $MIN_PLAYERS)"
GAME_OUT="$(run_script "game deploy" "$ROOT/contracts" "script/DeployGame.s.sol:DeployGame" \
  "LIFE_TOKEN_ADDRESS=$LIFE JURY_TOKEN_ADDRESS=$JURY CRISP_VOTING_PLUGIN_ADDRESS=$PLUGIN FEE_TOKEN_ADDRESS=$FEE_TOKEN CAMPAIGN_DURATION=$CAMPAIGN_DURATION BALLOT_DURATION=$BALLOT_DURATION TALLY_GRACE=$TALLY_GRACE TEAM_COUNT=$TEAM_COUNT MIN_MEMBERS_PER_TEAM=$MIN_MEMBERS_PER_TEAM MIN_PLAYERS=$MIN_PLAYERS MERGE_AT=$MERGE_AT FINALISTS=$FINALISTS MAX_MISSED_CHECKINS=$MAX_MISSED_CHECKINS ENTRY_FEE=$ENTRY_FEE")"
GAME="$(pick "$GAME_OUT" GAME)"
[ -n "$GAME" ] || { echo "$GAME_OUT" | tail -25; fail "could not parse the game address"; }
DEPLOY_BLOCK="$(cast block-number --rpc-url "$RPC" 2>/dev/null || echo 0)"
echo "  GAME $GAME (block $DEPLOY_BLOCK)"

# ─── 3b. lobby factory ──────────────────────────────────────────────────────────────────────────
#
# Deployed once and shared by every lobby after it, which is only possible because the plugin
# records a census provider per round rather than globally.

step "deploying the lobby factory"
FACTORY_OUT="$(run_script "factory deploy" "$ROOT/contracts" "script/DeployFactory.s.sol:DeployFactory" \
  "CRISP_VOTING_PLUGIN_ADDRESS=$PLUGIN FEE_TOKEN_ADDRESS=$FEE_TOKEN")"
FACTORY="$(pick "$FACTORY_OUT" FACTORY)"
NAMES="$(pick "$FACTORY_OUT" NAMES)"
[ -n "$FACTORY" ] || { echo "$FACTORY_OUT" | tail -20 >&2; fail "could not parse the factory address"; }
echo "  FACTORY $FACTORY"
echo "  NAMES   $NAMES"

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
  NEED=$MIN_PLAYERS
  step "rehearsing: seating $NEED players (the lobby floor) and opening a round"

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
FACTORY=$FACTORY
LIFE=$LIFE
JURY=$JURY
DEPLOY_BLOCK=$DEPLOY_BLOCK
TEAM_COUNT=$TEAM_COUNT
MIN_MEMBERS_PER_TEAM=$MIN_MEMBERS_PER_TEAM
MIN_PLAYERS=$MIN_PLAYERS
CAMPAIGN_DURATION=$CAMPAIGN_DURATION
BALLOT_DURATION=$BALLOT_DURATION
TALLY_GRACE=$TALLY_GRACE
EOF

# Carried over from the previous app/.env rather than regenerated: PINATA_JWT is a credential the
# deploy has no way to know, and silently dropping it on every redeploy turns campaign posts back
# into the on-chain fallback without anyone noticing.
PINATA_JWT="$(sed -n 's/^PINATA_JWT=//p' "$ROOT/app/.env" 2>/dev/null | head -1)"
step "writing app/.env"
# Gitignored: the backup inherits every credential the live file has, and a tracked copy of
# app/.env is a leak with an extra step.
[ -f "$ROOT/app/.env" ] && cp "$ROOT/app/.env" "$ROOT/app/.env.bak"

cat > "$ROOT/app/.env" <<EOF
# Generated by scripts/deploy-sepolia.sh — regenerate rather than hand-edit.
NEXT_PUBLIC_GAME_ADDRESS=$GAME
NEXT_PUBLIC_GAME_FACTORY_ADDRESS=$FACTORY
NEXT_PUBLIC_NAME_REGISTRY_ADDRESS=$NAMES
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
${PINATA_JWT:+PINATA_JWT=$PINATA_JWT
}NEXT_PUBLIC_SECONDS_PER_BLOCK=12
EOF
echo "  app/.env written (previous copy at app/.env.bak)"

cat <<EOF

$(printf '\033[1m')Deployed to Sepolia.$(printf '\033[0m')

  GAME    $GAME
  FACTORY $FACTORY
  PLUGIN  $PLUGIN
  DAO     $DAO
  LIFE    $LIFE
  JURY    $JURY

  Recorded in .sepolia.env.

  $(printf '\033[1m')Still to do:$(printf '\033[0m')

  1. bun run app:dev   — app/.env already points at this deployment.

  2. Import the deployer (or any funded key) into MetaMask on Sepolia, join $MIN_PLAYERS
     players across $TEAM_COUNT teams (the floor; up to $CAPACITY may join), then Start. Players need Sepolia ETH for gas but no fee tokens:
     the E3 fee comes from the pot.

  3. The campaign window is ${CAMPAIGN_DURATION}s. The ballot cannot open before the committee
     publishes its key, so watch that the key lands inside that window on the first round and
     raise CAMPAIGN_DURATION if it does not.

EOF
