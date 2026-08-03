import type { FC } from "react";
import type { Address } from "viem";
import { useHistory } from "../hooks/useHistory";
import { useNames, displayName } from "../hooks/useNames";
import { tribe } from "../utils/tribes";

interface HistoryProps {
  roundCount: number;
  players: Address[];
}

/// What has happened so far.
///
/// The reveal shows the current round and then loses it, so a game that runs for a day used to
/// remember nothing of itself. This is the record: who went, in which round, and by how many votes.
export const History: FC<HistoryProps> = ({ roundCount, players }) => {
  const entries = useHistory(roundCount);
  const names = useNames(players);

  if (entries.length === 0) return null;

  return (
    <section className="un-panel un-stack" style={{ gap: 12 }}>
      <div className="un-label-dim">The record · {entries.length} events</div>

      <ol className="un-timeline">
        {entries.map((e, i) => (
          <li key={`${e.round}-${e.kind}-${i}`} className="un-timeline-row">
            <span className="un-timeline-round">R{String(e.round + 1).padStart(2, "0")}</span>
            <span className="un-timeline-text">{describe(e, names)}</span>
            {"counts" in e && e.counts.length > 0 && (
              <span className="un-timeline-counts">{e.counts.map((c) => c.toString()).join(" · ")}</span>
            )}
          </li>
        ))}
      </ol>
    </section>
  );
};

function describe(e: ReturnType<typeof useHistory>[number], names: Record<string, string>) {
  switch (e.kind) {
    case "council": {
      const t = tribe(e.team);
      return (
        <>
          <strong style={{ color: t?.color }}>{t?.name ?? `Team ${e.team}`}</strong> was sent to council
        </>
      );
    }
    case "eliminated": {
      const t = tribe(e.team);
      return (
        <>
          <strong>{displayName(e.player, names)}</strong> was voted out
          {t && <span style={{ color: t.color }}> · {t.name}</span>}
        </>
      );
    }
    case "forfeited":
      return (
        <>
          <strong>{displayName(e.player, names)}</strong> forfeited — missed too many check-ins
        </>
      );
    case "void":
      return <>Nobody voted. The round was void.</>;
    case "aborted":
      return <>The round was abandoned — no tally arrived.</>;
    case "merged":
      return <>The tribes dissolved at {e.survivors} survivors</>;
    case "won":
      return (
        <>
          <strong>{displayName(e.player, names)}</strong> won the pot
        </>
      );
  }
}
