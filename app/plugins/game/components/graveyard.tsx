import type { FC } from "react";
import type { Address } from "viem";
import { useReadContract, useReadContracts, useWriteContract } from "wagmi";
import { GraveyardMarkAbi } from "../artifacts/GraveyardMark";
import { useGameTx, txLabel } from "../hooks/useGameTx";
import { displayName } from "../hooks/useNames";
import { sameAddress } from "../utils/tribes";

interface GraveyardProps {
  contract: Address;
  alive: Address[];
  names: Record<string, string>;
  self?: Address;
  /// Whether the connected wallet has been eliminated, and so may mark.
  isJuror: boolean;
  roundId: number;
}

/// What the dead do.
///
/// Being voted out otherwise means hours of nothing followed by one jury vote, and it happens first
/// to the people who most need a reason to stay in the room. This gives the graveyard one public
/// act per round: name a living player.
///
/// It is deliberately powerless. Real power would turn every elimination into recruitment and hand
/// the endgame to whoever assembled the biggest bloc of the already-defeated. An accusation nobody
/// has to honour is the useful middle — it feeds the campaign and changes nothing by force.
export const Graveyard: FC<GraveyardProps> = ({
  contract,
  alive,
  names,
  self,
  isJuror,
  roundId,
}) => {
  const { writeContractAsync } = useWriteContract();
  const tx = useGameTx();

  const { data: counts, refetch: refetchCounts } = useReadContracts({
    contracts: alive.map((p) => ({
      address: contract,
      abi: GraveyardMarkAbi,
      functionName: "marksFor" as const,
      args: [BigInt(roundId), p],
    })),
    query: { enabled: alive.length > 0, refetchInterval: 15_000 },
  });

  const { data: mine, refetch: refetchMine } = useReadContract({
    address: contract,
    abi: GraveyardMarkAbi,
    functionName: "markOf",
    args: self ? [BigInt(roundId), self] : undefined,
    query: { enabled: !!self, refetchInterval: 15_000 },
  });

  const marked = mine as Address | undefined;

  const tally = alive.map((player, i) => ({
    player,
    marks: counts?.[i]?.status === "success" ? Number(counts[i].result as bigint) : 0,
  }));
  const total = tally.reduce((sum, t) => sum + t.marks, 0);
  const most = Math.max(0, ...tally.map((t) => t.marks));
  const leaders = tally.filter((t) => t.marks === most && most > 0);
  const consensus = leaders.length === 1 ? leaders[0] : undefined;

  const mark = (candidate: Address) =>
    tx
      .run("mark", () =>
        writeContractAsync({
          address: contract,
          abi: GraveyardMarkAbi,
          functionName: "mark",
          args: [candidate],
        })
      )
      .then((ok) => {
        if (ok) {
          void refetchCounts();
          void refetchMine();
        }
      });

  // Hidden entirely until the graveyard exists or the viewer is in it. An empty panel labelled
  // "the dead" on round one is just clutter.
  if (total === 0 && !isJuror) return null;

  return (
    <section className="un-panel un-stack">
      <div className="un-spread">
        <div className="un-label-dim">The graveyard points</div>
        {consensus && (
          <span className="un-tag un-tag-block">
            {displayName(consensus.player, names)} · {consensus.marks}
          </span>
        )}
      </div>

      <p className="un-prose">
        {isJuror
          ? "You are out, but you are not gone. Name someone still breathing — it carries no weight at all, and everyone can see it."
          : "The eliminated have named someone. It does nothing on its own. Whether that means anything is up to the living."}
      </p>

      <div className="un-stack" style={{ gap: 8 }}>
        {tally.map(({ player, marks }) => (
          <button
            key={player}
            type="button"
            className={`un-option ${sameAddress(player, marked) ? "un-option-on" : ""}`}
            disabled={!isJuror || tx.isBusy}
            onClick={() => void mark(player)}
          >
            <span className="un-option-name">{displayName(player, names)}</span>
            <span className="un-mono" style={{ marginLeft: "auto" }}>
              {marks || ""}
            </span>
            {sameAddress(player, marked) && <span className="un-tag un-tag-you">YOURS</span>}
          </button>
        ))}
      </div>

      {isJuror && (
        <span className="un-fine">
          {tx.isBusy ? txLabel(tx.phase, "") : "Change it as often as you like. It is only a finger."}
        </span>
      )}
    </section>
  );
};
