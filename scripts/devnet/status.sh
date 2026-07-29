#!/usr/bin/env bash
#
# What is actually running, and what state the game is in.
#
# Most confusing failures here are not contract failures — they are a service being down or a
# wallet pointed at the wrong port. This answers that in one shot.
#
# Usage: status.sh
set -uo pipefail

PORT="${ANVIL_PORT:-8545}"
RPC="http://127.0.0.1:${PORT}"
CRISP_SERVER="${CRISP_SERVER_URL:-http://127.0.0.1:4000}"
if [ "$PORT" = "8545" ]; then PROGRAM_PORT=13151; QUIC=9201; else PROGRAM_PORT=13152; QUIC=9301; fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
up()   { lsof -nP -i:"$1" >/dev/null 2>&1 && printf '  \033[32m●\033[0m %-22s %s\n' "$2" "up" || printf '  \033[31m○\033[0m %-22s %s\n' "$2" "DOWN"; }

bold "services"
up "$PORT"         "anvil ($PORT)"
up 4000            "crisp server (4000)"
up "$PROGRAM_PORT" "program server ($PROGRAM_PORT)"
up "$QUIC"         "ciphernodes ($QUIC+)"

BLOCK="$(cast block-number --rpc-url "$RPC" 2>/dev/null || echo '')"
if [ -z "$BLOCK" ]; then
  printf '\n  no chain at %s — start one with: bun run devnet:up\n\n' "$RPC"
  exit 0
fi
echo "  chain at block $BLOCK"

GAME="$(grep -E '^NEXT_PUBLIC_GAME_ADDRESS=' "$ROOT/app/.env" 2>/dev/null | cut -d= -f2)"
if [ -z "$GAME" ]; then
  printf '\n  no game configured in app/.env — deploy one with: bun run play\n\n'
  exit 0
fi

bold "game $GAME"
call() { cast call "$GAME" "$1" --rpc-url "$RPC" 2>/dev/null | head -1; }
STAGE="$(call 'stage()(uint8)')"
case "${STAGE:-}" in
  0) STAGE_NAME="Lobby" ;; 1) STAGE_NAME="Playing" ;;
  2) STAGE_NAME="Jury"  ;; 3) STAGE_NAME="Ended"   ;; *) STAGE_NAME="unknown" ;;
esac
printf '  %-14s %s\n' "stage"  "$STAGE_NAME"
printf '  %-14s %s\n' "alive"  "$(call 'aliveCount()(uint256)')"
printf '  %-14s %s\n' "jurors" "$(cast call "$GAME" 'jurors()(address[])' --rpc-url "$RPC" 2>/dev/null | tr -d '[]' | tr ',' '\n' | grep -c '0x' || echo 0)"
printf '  %-14s %s\n' "pot"    "$(call 'pot()(uint256)')"
printf '  %-14s %s\n' "rounds" "$(call 'roundCount()(uint256)')"

ROUNDS="$(call 'roundCount()(uint256)')"; ROUNDS="${ROUNDS%% *}"
if [ -n "$ROUNDS" ] && [ "$ROUNDS" != "0" ]; then
  RID=$((ROUNDS - 1))
  read -r E3 _OPENED OPENS CLOSES SETTLED OUTCOME <<<"$(
    cast call "$GAME" 'getRound(uint256)(uint256,uint64,uint64,uint64,bool,address)' "$RID" \
      --rpc-url "$RPC" 2>/dev/null | sed 's/ \[.*\]//' | tr '\n' ' '
  )"
  NOW="$(date +%s)"
  if   [ "$SETTLED" = "true" ];        then PHASE="settled"
  elif [ "$NOW" -lt "${OPENS:-0}" ];   then PHASE="campaign"
  elif [ "$NOW" -lt "${CLOSES:-0}" ];  then PHASE="ballot"
  else                                      PHASE="tally"; fi

  bold "round $((RID + 1))  (e3 #$E3)"
  printf '  %-14s %s\n' "phase" "$PHASE"
  printf '  %-14s %s\n' "outcome" "$OUTCOME"

  # The committee key is what actually gates voting, so it is worth showing separately from the clock.
  STATE="$(curl -s -X POST "$CRISP_SERVER/state/lite" -H 'Content-Type: application/json' \
    -d "{\"round_id\":$E3}" 2>/dev/null)"
  if echo "$STATE" | grep -qE '"committee_public_key":\[[0-9]'; then
    printf '  %-14s %s\n' "committee key" "published — voting possible"
  elif [ -n "$STATE" ]; then
    printf '  %-14s %s\n' "committee key" "NOT yet published — voting will fail"
  else
    printf '  %-14s %s\n' "committee key" "crisp server not answering"
  fi
  echo "$STATE" | grep -oE '"vote_count":"?[0-9]+"?' | head -1 | sed 's/^/  ballots        /'
fi
echo
