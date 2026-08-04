import { useReadContracts, useReadContract } from "wagmi";
import { useGameAddress } from "../utils/activeGame";
import { SurvivalGameAbi } from "../artifacts/SurvivalGame";
import { Stage, ZERO_ADDRESS, type RoundKind } from "../utils/gameTypes";
import type { GameConfig, GameState, Round } from "../utils/gameTypes";
import type { Address } from "viem";

/// Built per call rather than once at module scope, because the address is now state: a module-level
/// constant would freeze whichever lobby was configured at build time.
function gameContractFor(address: Address) {
  return { address, abi: SurvivalGameAbi } as const;
}

/// Reads the whole game state in one multicall.
///
/// Refetches on an interval because rounds advance by wall clock, not by transactions — there is
/// no event to wait for when a campaign window rolls over into a ballot window.
export function useGame(pollMs = 10_000) {
  const gameContract = gameContractFor(useGameAddress());
  const { data, isLoading, error, refetch } = useReadContracts({
    contracts: [
      { ...gameContract, functionName: "stage" },
      { ...gameContract, functionName: "config" },
      { ...gameContract, functionName: "alivePlayers" },
      { ...gameContract, functionName: "jurors" },
      { ...gameContract, functionName: "winner" },
      { ...gameContract, functionName: "pot" },
      { ...gameContract, functionName: "roundCount" },
      // Only used to decide whether to offer `abortRound`, which is owner-gated. Folded in here
      // rather than read separately: it never changes, and one more entry in a multicall is free
      // where another hook would be another round trip on every poll.
      { ...gameContract, functionName: "owner" },
    ],
    query: { enabled: !!gameContract.address, refetchInterval: pollMs },
  });

  const game: GameState | undefined = data?.every((r) => r.status === "success")
    ? {
        stage: Number(data[0].result) as Stage,
        config: toConfig(data[1].result as readonly unknown[]),
        alive: data[2].result as Address[],
        jurors: data[3].result as Address[],
        winner: data[4].result as Address,
        pot: data[5].result as bigint,
        roundCount: Number(data[6].result as bigint),
        owner: data[7].result as Address,
      }
    : undefined;

  return { game, isLoading, error, refetch };
}

/// Reads a single round, including the candidate list a ballot is cast against.
export function useRound(roundId: number | undefined, pollMs = 10_000) {
  const gameContract = gameContractFor(useGameAddress());
  const enabled = roundId !== undefined && roundId >= 0;

  const { data, isLoading, error, refetch } = useReadContracts({
    contracts: [
      { ...gameContract, functionName: "getRound", args: [BigInt(roundId ?? 0)] },
      { ...gameContract, functionName: "candidatesOf", args: [BigInt(roundId ?? 0)] },
      { ...gameContract, functionName: "votersOf", args: [BigInt(roundId ?? 0)] },
      { ...gameContract, functionName: "candidateTeamsOf", args: [BigInt(roundId ?? 0)] },
    ],
    query: { enabled: enabled && !!gameContract.address, refetchInterval: pollMs },
  });

  const round: Round | undefined =
    enabled && data?.every((r) => r.status === "success")
      ? toRound(
          roundId,
          data[0].result as readonly unknown[],
          data[1].result as Address[],
          data[2].result as Address[],
          data[3].result as readonly number[]
        )
      : undefined;

  return { round, isLoading, error, refetch };
}

/// Team id per player, keyed by lowercased address.
///
/// Read per player rather than from a single call because the contract stores it as a mapping —
/// there is no bulk accessor, and inventing one on-chain to save a few RPC calls is the wrong
/// trade for a roster this size.
export function useTeams(players: Address[], pollMs = 30_000) {
  const gameContract = gameContractFor(useGameAddress());
  const { data } = useReadContracts({
    contracts: players.map((p) => ({ ...gameContract, functionName: "teamOf" as const, args: [p] })),
    query: { enabled: players.length > 0 && !!gameContract.address, refetchInterval: pollMs },
  });

  const teamOf: Record<string, number> = {};
  players.forEach((p, i) => {
    const entry = data?.[i];
    teamOf[p.toLowerCase()] = entry?.status === "success" ? Number(entry.result) : 0;
  });

  return teamOf;
}

/// The index of the round currently in play, or undefined before the game starts.
export function useCurrentRoundId(pollMs = 10_000) {
  const gameContract = gameContractFor(useGameAddress());
  const { data } = useReadContract({
    ...gameContract,
    functionName: "roundCount",
    query: { enabled: !!gameContract.address, refetchInterval: pollMs },
  });

  const count = data === undefined ? 0 : Number(data as bigint);
  return count === 0 ? undefined : count - 1;
}

function toConfig(raw: readonly unknown[]): GameConfig {
  return {
    campaignDuration: raw[0] as bigint,
    ballotDuration: raw[1] as bigint,
    tallyGrace: raw[2] as bigint,
    teamCount: Number(raw[3]),
    minMembersPerTeam: Number(raw[4]),
    minPlayers: Number(raw[5]),
    lobbyTimeout: raw[6] as bigint,
    mergeAt: Number(raw[7]),
    finalists: Number(raw[8]),
    maxMissedCheckIns: Number(raw[9]),
    entryFee: raw[10] as bigint,
  };
}

function toRound(
  id: number,
  raw: readonly unknown[],
  candidates: Address[],
  voters: Address[],
  candidateTeams: readonly number[]
): Round {
  return {
    id,
    kind: Number(raw[0]) as RoundKind,
    proposalId: raw[1] as bigint,
    e3Id: raw[2] as bigint,
    openedAt: raw[3] as bigint,
    ballotOpensAt: raw[4] as bigint,
    ballotClosesAt: raw[5] as bigint,
    settled: raw[6] as boolean,
    outcome: (raw[7] as Address) ?? ZERO_ADDRESS,
    targetTeam: Number(raw[8] ?? 0),
    candidates,
    candidateTeams: Array.from(candidateTeams ?? []).map(Number),
    voters,
  };
}
