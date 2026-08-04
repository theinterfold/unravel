import { useState } from "react";
import { useReadContract, useWriteContract } from "wagmi";
import type { Address } from "viem";
import { useGameAddress } from "../utils/activeGame";
import { SurvivalGameAbi } from "../artifacts/SurvivalGame";
import { publicClient } from "../utils/client";

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

  const { writeContractAsync } = useWriteContract();
  // Tracked here rather than taken from wagmi: `isPending` covers signing only, and this hook now
  // waits for the receipt too. Using it would re-enable the button while the check-in is still in
  // flight, inviting a second one.
  const [isPending, setPending] = useState(false);

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
      setPending(true);
      try {
        const hash = await writeContractAsync({
          address: gameAddress,
          abi: SurvivalGameAbi,
          functionName: "checkIn",
          args: [],
        });
        // Waited on before refetching: `lastCheckIn` does not change until the transaction is
        // mined, so refetching on send reads the old value and the UI keeps insisting you still
        // owe a check-in — the one thing that gets a player eliminated for inactivity.
        await publicClient.waitForTransactionReceipt({ hash });
        void refetch();
        return hash;
      } finally {
        setPending(false);
      }
    },
  };
}
