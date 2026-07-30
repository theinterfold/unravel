import { useEffect, useState, type FC } from "react";
import { parseAbiItem, type Address } from "viem";
import { useReadContracts } from "wagmi";
import { PUB_GAME_ADDRESS, PUB_DEPLOYMENT_BLOCK } from "@/constants";
import { SurvivalGameAbi } from "../artifacts/SurvivalGame";
import { publicClient } from "../utils/client";
import { shortAddress, sameAddress, tribe } from "../utils/tribes";

interface FinalistsProps {
  finalists: Address[];
  teamOf: Record<string, number>;
  jurors: Address[];
  roundCount: number;
  self?: Address;
}

const POSTED = parseAbiItem("event Posted(uint256 indexed round, address indexed player, string cid)");

/// The dossier the jury votes on.
///
/// Only facts the chain actually holds: how many rounds they lasted, how much they said in public,
/// and how close they came to dying of admin. The design also shows "times on the block" and a
/// quoted campaign line; neither is here, because the first needs a per-round reconstruction of
/// council membership and the second needs the post bodies, which are IPFS CIDs this app does not
/// yet resolve. An invented dossier would be worse than a short one — the jury is about to spend
/// real money on it.
export const Finalists: FC<FinalistsProps> = ({ finalists, teamOf, jurors, roundCount, self }) => {
  const posts = usePostCounts(finalists);

  const { data } = useReadContracts({
    contracts: finalists.map((p) => ({
      address: PUB_GAME_ADDRESS,
      abi: SurvivalGameAbi,
      functionName: "lastCheckIn" as const,
      args: [p],
    })),
    query: { enabled: finalists.length > 0 },
  });

  return (
    <section className="un-chamber un-stack">
      <div className="un-label-dim">The chamber · {jurors.length} jurors</div>
      <p className="un-prose">
        {jurors.length} of you were voted out. {jurors.length === 1 ? "That one" : "Those"} now hold the only ballots
        that matter. {finalists.length} finalists remain, and the pot goes to whichever of them the dead resent least.
      </p>

      <div className="un-grid-2">
        {finalists.map((player, i) => {
          const t = tribe(teamOf[player.toLowerCase()] ?? 0);
          const seen = data?.[i]?.status === "success" ? Number(data[i].result as bigint) : 0;
          // Mirrors _applyForfeits: lastCheckIn stores roundId + 1, and 0 means never.
          const missed = seen === 0 ? roundCount : roundCount - seen;

          return (
            <article key={player} className={`un-vitrine ${sameAddress(player, self) ? "un-vitrine-won" : ""}`}>
              <div className="un-row" style={{ gap: 12, marginBottom: 16 }}>
                <span className="un-mono" style={{ fontSize: 17, color: "var(--un-fg)" }}>
                  {shortAddress(player)}
                </span>
                {t && (
                  <span className="un-piece-tribe" style={{ color: t.color }}>
                    {t.name}
                  </span>
                )}
                {sameAddress(player, self) && <span className="un-tag un-tag-you">YOU</span>}
              </div>

              <dl className="un-stack" style={{ gap: 9 }}>
                <Fact label="Rounds survived" value={roundCount} />
                <Fact label="Things said in public" value={posts[player.toLowerCase()] ?? 0} />
                <Fact label="Missed check-ins" value={Math.max(0, missed)} alarm={missed > 0} last />
              </dl>
            </article>
          );
        })}
      </div>
    </section>
  );
};

const Fact: FC<{ label: string; value: number; alarm?: boolean; last?: boolean }> = ({
  label,
  value,
  alarm,
  last,
}) => (
  <div
    style={{
      display: "flex",
      justifyContent: "space-between",
      gap: 12,
      fontSize: 12.5,
      borderBottom: last ? undefined : "1px solid rgba(255,255,255,.1)",
      paddingBottom: last ? 0 : 8,
    }}
  >
    <dt>{label}</dt>
    <dd
      className="un-mono"
      style={{ margin: 0, color: alarm ? "var(--un-condemned)" : "var(--un-fg-2)" }}
    >
      {value}
    </dd>
  </div>
);

/// How much each finalist said in public, across the whole game.
function usePostCounts(players: Address[]): Record<string, number> {
  const [counts, setCounts] = useState<Record<string, number>>({});
  const key = players.join(",");

  useEffect(() => {
    if (players.length === 0) return;
    let cancelled = false;

    const load = async () => {
      try {
        const logs = await publicClient.getLogs({
          address: PUB_GAME_ADDRESS,
          event: POSTED,
          fromBlock: BigInt(PUB_DEPLOYMENT_BLOCK),
          toBlock: "latest",
        });
        if (cancelled) return;

        const tally: Record<string, number> = {};
        for (const log of logs) {
          const who = (log.args.player as Address | undefined)?.toLowerCase();
          if (who) tally[who] = (tally[who] ?? 0) + 1;
        }
        setCounts(tally);
      } catch (e) {
        console.error("usePostCounts:", e);
      }
    };

    void load();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  return counts;
}
