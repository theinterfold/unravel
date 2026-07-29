import { useReadContracts, useReadContract } from "wagmi";
import { PUB_GAME_ADDRESS } from "@/constants";
import { SurvivalGameAbi } from "../artifacts/SurvivalGame";
import { Stage, ZERO_ADDRESS } from "../utils/gameTypes";
import type { GameConfig, GameState, Round } from "../utils/gameTypes";
import type { Address } from "viem";

const gameContract = { address: PUB_GAME_ADDRESS, abi: SurvivalGameAbi } as const;

/// Reads the whole game state in one multicall.
///
/// Refetches on an interval because rounds advance by wall clock, not by transactions — there is
/// no event to wait for when a campaign window rolls over into a ballot window.
export function useGame(pollMs = 10_000) {
  const { data, isLoading, error, refetch } = useReadContracts({
    contracts: [
      { ...gameContract, functionName: "stage" },
      { ...gameContract, functionName: "config" },
      { ...gameContract, functionName: "alivePlayers" },
      { ...gameContract, functionName: "jurors" },
      { ...gameContract, functionName: "winner" },
      { ...gameContract, functionName: "pot" },
      { ...gameContract, functionName: "roundCount" },
    ],
    query: { refetchInterval: pollMs },
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
      }
    : undefined;

  return { game, isLoading, error, refetch };
}

/// Reads a single round, including the candidate list a ballot is cast against.
export function useRound(roundId: number | undefined, pollMs = 10_000) {
  const enabled = roundId !== undefined && roundId >= 0;

  const { data, isLoading, error, refetch } = useReadContracts({
    contracts: [
      { ...gameContract, functionName: "getRound", args: [BigInt(roundId ?? 0)] },
      { ...gameContract, functionName: "candidatesOf", args: [BigInt(roundId ?? 0)] },
      { ...gameContract, functionName: "votersOf", args: [BigInt(roundId ?? 0)] },
    ],
    query: { enabled, refetchInterval: pollMs },
  });

  const round: Round | undefined =
    enabled && data?.every((r) => r.status === "success")
      ? toRound(roundId, data[0].result as readonly unknown[], data[1].result as Address[], data[2].result as Address[])
      : undefined;

  return { round, isLoading, error, refetch };
}

/// The index of the round currently in play, or undefined before the game starts.
export function useCurrentRoundId(pollMs = 10_000) {
  const { data } = useReadContract({
    ...gameContract,
    functionName: "roundCount",
    query: { refetchInterval: pollMs },
  });

  const count = data === undefined ? 0 : Number(data as bigint);
  return count === 0 ? undefined : count - 1;
}

function toConfig(raw: readonly unknown[]): GameConfig {
  return {
    campaignDuration: raw[0] as bigint,
    ballotDuration: raw[1] as bigint,
    tallyGrace: raw[2] as bigint,
    rosterSize: Number(raw[3]),
    finalists: Number(raw[4]),
    maxMissedCheckIns: Number(raw[5]),
    entryFee: raw[6] as bigint,
  };
}

function toRound(id: number, raw: readonly unknown[], candidates: Address[], voters: Address[]): Round {
  return {
    id,
    e3Id: raw[0] as bigint,
    openedAt: raw[1] as bigint,
    ballotOpensAt: raw[2] as bigint,
    ballotClosesAt: raw[3] as bigint,
    settled: raw[4] as boolean,
    outcome: (raw[5] as Address) ?? ZERO_ADDRESS,
    candidates,
    voters,
  };
}
