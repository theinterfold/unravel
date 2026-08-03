import { useReadContract, useWriteContract } from "wagmi";
import type { Address } from "viem";
import { useGameAddress } from "../utils/activeGame";
import { SurvivalGameAbi } from "../artifacts/SurvivalGame";

export type CheckInState = {
  /// Consecutive rounds missed, mirroring `_applyForfeits`.
  missed: number;
  /// Misses allowed before elimination. 0 means forfeits are disabled entirely.
  limit: number;
  /// Whether this round's check-in is already recorded.
  current: boolean;
  /// One more miss ends the game for this player.
  onLastLife: boolean;
  /// Forfeits cannot bite yet — the contract skips them while `roundId <= limit`.
  immature: boolean;
  checkIn: () => Promise<unknown>;
  isPending: boolean;
  refetch: () => void;
};

/// Liveness, and how close the player is to dying of admin.
///
/// This deserves its own hook because the arithmetic is easy to get subtly wrong and the cost of
/// getting it wrong is a player being told they are safe when they are one round from elimination.
/// It mirrors `SurvivalGame._applyForfeits` exactly:
///
///   seen   = lastCheckIn[player]      // stored as roundId + 1, so 0 means "never"
///   missed = seen == 0 ? roundId : roundId - (seen - 1)
///   forfeit when missed > limit, and only once roundId > limit
///
/// The `roundId > limit` guard matters: early in a game the count can read as "2 missed" while no
/// forfeit is possible yet, and screaming at a player who is in no danger is how an alarm gets
/// ignored later.
export function useCheckIn(
  player: Address | undefined,
  roundId: number | undefined,
  limit: number,
  pollMs = 15_000
): CheckInState {
  const gameAddress = useGameAddress();
  const { data, refetch } = useReadContract({
    address: gameAddress,
    abi: SurvivalGameAbi,
    functionName: "lastCheckIn",
    args: player ? [player] : undefined,
    query: { enabled: !!player, refetchInterval: pollMs },
  });

  const { writeContractAsync, isPending } = useWriteContract();

  const seen = data === undefined ? 0 : Number(data as bigint);
  const round = roundId ?? 0;
  const missed = seen === 0 ? round : round - (seen - 1);
  const immature = limit === 0 || round <= limit;

  return {
    missed: Math.max(0, missed),
    limit,
    current: seen === round + 1,
    onLastLife: !immature && missed >= limit,
    immature,
    isPending,
    refetch: () => void refetch(),
    checkIn: async () => {
      const hash = await writeContractAsync({
        address: gameAddress,
        abi: SurvivalGameAbi,
        functionName: "checkIn",
        args: [],
      });
      void refetch();
      return hash;
    },
  };
}
