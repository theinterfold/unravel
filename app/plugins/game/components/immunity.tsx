import type { FC } from "react";
import type { Address } from "viem";
import { useReadContract, useReadContracts, useWriteContract } from "wagmi";
import { PublicImmunityVoteAbi } from "../artifacts/PublicImmunityVote";
import { useGameTx, txLabel } from "../hooks/useGameTx";
import { displayName } from "../hooks/useNames";
import { sameAddress, tribe } from "../utils/tribes";

interface ImmunityProps {
  contract: Address;
  /// Players who may be protected — the living.
  alive: Address[];
  names: Record<string, string>;
  self?: Address;
  /// Whether the connected wallet is alive, and so may vote.
  canVote: boolean;
  teamOf: Record<string, number>;
}

/// The public half of every round.
///
/// Deliberately the loudest panel in the round view. The secret ballot is the game's mechanism, but
/// a game whose only act is invisible has nothing to watch — this is the part players can point at,
/// argue about, and be held to. You protect someone under your own name while the knife stays
/// sealed, and the gap between the two is where the game actually happens.
export const Immunity: FC<ImmunityProps> = ({ contract, alive, names, self, canVote, teamOf }) => {
  const { writeContractAsync } = useWriteContract();
  const tx = useGameTx();

  const { data: pending, refetch: refetchRound } = useReadContract({
    address: contract,
    abi: PublicImmunityVoteAbi,
    functionName: "pendingRound",
    query: { refetchInterval: 15_000 },
  });

  const round = pending as bigint | undefined;

  // One read per candidate rather than a bespoke aggregate view: the roster is capped at ten, and
  // a multicall of ten is cheaper than another contract function to maintain.
  const { data: counts, refetch: refetchCounts } = useReadContracts({
    contracts: alive.map((p) => ({
      address: contract,
      abi: PublicImmunityVoteAbi,
      functionName: "votesFor" as const,
      args: [round ?? 0n, p],
    })),
    query: { enabled: round !== undefined && alive.length > 0, refetchInterval: 15_000 },
  });

  const { data: mine, refetch: refetchMine } = useReadContract({
    address: contract,
    abi: PublicImmunityVoteAbi,
    functionName: "ballotOf",
    args: round !== undefined && self ? [round, self] : undefined,
    query: { enabled: round !== undefined && !!self, refetchInterval: 15_000 },
  });

  const votedFor = mine as Address | undefined;

  const tally = alive.map((player, i) => ({
    player,
    votes: counts?.[i]?.status === "success" ? Number(counts[i].result as bigint) : 0,
  }));
  const most = Math.max(0, ...tally.map((t) => t.votes));
  // Mirrors `immuneFor`: a tie protects nobody, so the leader is only shown when it is unique.
  const leaders = tally.filter((t) => t.votes === most && most > 0);
  const protectedPlayer = leaders.length === 1 ? leaders[0].player : undefined;

  const vote = (candidate: Address) =>
    tx
      .run("voteForImmunity", () =>
        writeContractAsync({
          address: contract,
          abi: PublicImmunityVoteAbi,
          functionName: "voteForImmunity",
          args: [candidate],
        })
      )
      .then((ok) => {
        if (ok) {
          void refetchCounts();
          void refetchMine();
          void refetchRound();
        }
      });

  return (
    <section className="un-panel un-stack">
      <div className="un-spread">
        <div className="un-label-dim">Immunity · out loud</div>
        {protectedPlayer ? (
          <span className="un-tag un-tag-you">
            {displayName(protectedPlayer, names)} IS SAFE
          </span>
        ) : (
          <span className="un-fine">nobody protected</span>
        )}
      </div>

      <p className="un-prose">
        Everyone can see this vote and who cast it. Whoever leads when the next round opens cannot be
        eliminated in it — so you must argue for someone in public while your ballot stays sealed.
      </p>

      <div className="un-stack" style={{ gap: 8 }}>
        {tally.map(({ player, votes }) => {
          const t = tribe(teamOf[player.toLowerCase()] ?? 0);
          const isMine = sameAddress(player, votedFor);
          return (
            <button
              key={player}
              type="button"
              className={`un-option ${isMine ? "un-option-on" : ""}`}
              disabled={!canVote || tx.isBusy}
              onClick={() => void vote(player)}
            >
              <span className="un-option-name">
                {displayName(player, names)}
                {sameAddress(player, self) && " (you)"}
              </span>
              {t && (
                <span className="un-piece-tribe" style={{ color: t.color }}>
                  {t.name}
                </span>
              )}
              <span className="un-mono" style={{ marginLeft: "auto" }}>
                {votes}
              </span>
              {isMine && <span className="un-tag un-tag-you">YOUR PICK</span>}
            </button>
          );
        })}
      </div>

      <span className="un-fine">
        {!canVote
          ? "Only the living vote on immunity."
          : tx.isBusy
            ? txLabel(tx.phase, "")
            : votedFor
              ? "Change your mind freely — it locks when the next round opens."
              : "Pick someone to protect. Everyone will see it was you."}
      </span>
    </section>
  );
};
