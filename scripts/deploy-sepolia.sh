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

# ─── 1. the plugin's reference token ────────────────────────────────────────────────────────────
#
# Not a game's badges — those are deployed per lobby by the factory. The plugin still needs *a*
# token at initialisation, and under constant credits with a requester-supplied census the only
# thing it is used for is the ERC-6372 clock that stamps each proposal's snapshot. Nothing is ever
# minted here.

step "deploying the plugin's reference token"
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

# ─── 3. lobby factory ──────────────────────────────────────────────────────────────────────────
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

# ─── 4. fee tokens ──────────────────────────────────────────────────────────────────────────────
#
# No pot is funded here, because no game is deployed here: lobbies are created from the app and
# funded by whoever creates them. This only puts fee tokens in the deployer's hands so they can
# stand one.

step "claiming fee tokens from the faucet"
if cast send "$FAUCET" "faucet()" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null 2>&1; then
  echo "  claimed"
else
  # Reverts once the deployer already holds enough, which is a success for our purposes.
  echo "  faucet declined (deployer already holds enough — continuing)"
fi
FEE_BALANCE="$(cast call "$FEE_TOKEN" "balanceOf(address)(uint256)" "$DEPLOYER" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')"
echo "  deployer holds ${FEE_BALANCE:-0} fee-token units"

DEPLOY_BLOCK="$(cast block-number --rpc-url "$RPC" 2>/dev/null || echo 0)"

# ─── 5. rehearse a lobby (dry run only) ─────────────────────────────────────────────────────────
#
# The check worth having. `startGame` opens the first round, which routes through the plugin into the
# real Interfold `request` — so this is where an ABI mismatch surfaces, and it surfaces as a revert
# with empty data that explains nothing. Finding that on a fork costs nothing; finding it after a live
# deploy means redeploying.
if [ "$DRY_RUN" = "1" ]; then
  NEED=$MIN_PLAYERS
  step "rehearsing: creating a lobby, seating $NEED players and opening a round"

  # The rehearsal now goes through the factory, because that is the only way a lobby is made — the
  # deploy no longer produces a standalone game. So this exercises the path players actually take.
  #
  # The creator funds the pot; joining is free. The funding has to cover the round fees, since the
  # pot pays for the game as well as the winner.
  FUNDING_UNITS=$((200 * 1000000))
  CONFIG="($CAMPAIGN_DURATION,$BALLOT_DURATION,$TALLY_GRACE,$TEAM_COUNT,$MIN_MEMBERS_PER_TEAM,$MIN_PLAYERS,86400,$MERGE_AT,$FINALISTS,$MAX_MISSED_CHECKINS,0)"

  # Approved to the factory, not the game: the game has no address until `create` returns.
  cast send "$FEE_TOKEN" "approve(address,uint256)" "$FACTORY" "$FUNDING_UNITS" \
    --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null 2>&1 || fail "approve to factory failed"

  cast send "$FACTORY" \
    "create((uint64,uint64,uint64,uint8,uint8,uint8,uint64,uint8,uint8,uint8,uint256),string,uint256)" \
    "$CONFIG" "Rehearsal" "$FUNDING_UNITS" --gas-limit 9000000 \
    --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null 2>&1 || fail "factory.create failed"

  GAME="$(cast call "$FACTORY" 'games(uint256)(address)' 0 --rpc-url "$RPC" 2>/dev/null)"
  [ -n "$GAME" ] || fail "the factory created no lobby"
  echo "  lobby $GAME"

  MNEMONIC="test test test test test test test test test test test junk"
  i=0
  while [ "$i" -lt "$NEED" ]; do
    KEY="$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index "$i" 2>/dev/null)"
    PLAYER="$(cast wallet address --private-key "$KEY")"
    TEAM=$(((i % TEAM_COUNT) + 1))

    # No faucet call and no approval: joining is free, so a player needs gas and nothing else.
    # That this loop is now three lines shorter is the point of the change.
    #
    # A fixed gas limit: estimation races the ERC20Votes checkpoint write, whose cost is
    # state-dependent, and an underestimate surfaces as an opaque out-of-gas.
    cast send "$GAME" "join(uint8)" "$TEAM" --gas-limit 500000 \
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
  echo "  pot $(cast call "$GAME" 'pot()(uint256)' --rpc-url "$RPC" 2>/dev/null) after the first round's fee"
  # An e3Id is only meaningful if Interfold agrees it exists; a misread offset would print a
  # plausible-looking number that belongs to no E3.
  cast call "$INTERFOLD_ADDRESS" "getE3(uint256)" "$E3" --rpc-url "$RPC" >/dev/null 2>&1 ||
    fail "the game recorded e3Id $E3 but Interfold has no such E3 — the request return was misread"
  echo "  Interfold confirms E3 $E3 exists"

  # The declaration has to survive the whole chain — game to plugin to Interfold to the CRISP
  # program — and if it does not, nothing errors: the coordinator falls back to deriving the
  # electorate from token balances, and a council round quietly enfranchises everybody. Reading it
  # back is the only way to know it arrived.
  MODE="$(cast call "$CRISP_PROGRAM" 'censusModeOf(uint256)(uint8)' "$E3" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')"
  case "${MODE:-}" in
    1) echo "  census mode BY_REQUESTER — the coordinator will ask the game who may vote" ;;
    0) fail "the round recorded census mode TOKEN. The coordinator will derive the electorate from
       LIFE holders, so council and jury rounds will enfranchise the wrong players." ;;
    *) fail "could not read censusModeOf($E3) from $CRISP_PROGRAM — is it the new CRISP program?" ;;
  esac

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
# Same reasoning: the dedicated gateway is account configuration, not deployment output. It is what
# makes reading a post back reliable — see pages/api/ipfs/cat.ts.
PINATA_GATEWAY="$(sed -n 's/^PINATA_GATEWAY=//p' "$ROOT/app/.env" 2>/dev/null | head -1)"
step "writing app/.env"
# Gitignored: the backup inherits every credential the live file has, and a tracked copy of
# app/.env is a leak with an extra step.
[ -f "$ROOT/app/.env" ] && cp "$ROOT/app/.env" "$ROOT/app/.env.bak"

cat > "$ROOT/app/.env" <<EOF
# Generated by scripts/deploy-sepolia.sh — regenerate rather than hand-edit.
# Left blank on purpose: this deploy creates no game. Lobbies come from the factory below, and the
# app opens on the browser until a player picks one. Set it to an address to pin the app to one
# game instead. The LIFE and JURY badges are per-lobby for the same reason and are not configured.
NEXT_PUBLIC_GAME_ADDRESS=
NEXT_PUBLIC_GAME_FACTORY_ADDRESS=$FACTORY
NEXT_PUBLIC_NAME_REGISTRY_ADDRESS=$NAMES
NEXT_PUBLIC_GAME_DEPLOYMENT_BLOCK=$DEPLOY_BLOCK

NEXT_PUBLIC_INTERFOLD_ADDRESS=$INTERFOLD_ADDRESS
NEXT_PUBLIC_INTERFOLD_FEE_TOKEN_ADDRESS=$FEE_TOKEN
# Testnet only. Creating a lobby now costs the creator real fee tokens, so without this the first
# thing anyone does is run out and have to go and find some by hand.
NEXT_PUBLIC_FAUCET_ADDRESS=$FAUCET
NEXT_PUBLIC_ENABLE_FAUCET=true
NEXT_PUBLIC_CRISP_PROGRAM_ADDRESS=$CRISP_PROGRAM
NEXT_PUBLIC_CRISP_VOTING_PLUGIN_ADDRESS=$PLUGIN
NEXT_PUBLIC_DAO_ADDRESS=$DAO
NEXT_PUBLIC_CRISP_SERVER_URL=$CRISP_SERVER

NEXT_PUBLIC_CHAIN_NAME=sepolia
NEXT_PUBLIC_WEB3_ENDPOINT=$RPC
# Where campaign posts are read back from. Without these every post in the game renders as
# "unreachable", which looks like the pin failed rather than like nothing was ever asked for it.
NEXT_PUBLIC_IPFS_ENDPOINTS=https://gateway.pinata.cloud/ipfs,https://dweb.link/ipfs,https://ipfs.io/ipfs
${PINATA_JWT:+PINATA_JWT=$PINATA_JWT
}${PINATA_GATEWAY:+PINATA_GATEWAY=$PINATA_GATEWAY
}NEXT_PUBLIC_SECONDS_PER_BLOCK=12
EOF
echo "  app/.env written (previous copy at app/.env.bak)"

cat <<EOF

$(printf '\033[1m')Deployed to Sepolia.$(printf '\033[0m')

  FACTORY $FACTORY
  PLUGIN  $PLUGIN
  DAO     $DAO

  No game was deployed. Create lobbies from the app; each mints its own LIFE and JURY badges.
  ($LIFE is the reference badge the plugin was initialised with, and belongs to no lobby.)

  Recorded in .sepolia.env.

  $(printf '\033[1m')Still to do:$(printf '\033[0m')

  1. bun run app:dev   — app/.env already points at this deployment.

  2. Start a lobby from the app: pick how many players it takes to begin, and how much you put up.
     You fund the pot yourself, and it pays both the E3 fees and the prize, so the form warns if
     the amount would not cover the rounds. Claim fee tokens from the faucet first.

  3. Import keys into MetaMask on Sepolia and join with each. Joining is free — players need
     Sepolia ETH for gas and nothing else. Anyone can Start once the lobby hits its floor.

  4. The campaign window is ${CAMPAIGN_DURATION}s. The ballot cannot open before the committee
     publishes its key, so watch that the key lands inside that window on the first round and
     raise CAMPAIGN_DURATION if it does not.

EOF
