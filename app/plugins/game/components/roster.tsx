import type { FC } from "react";
import type { Address } from "viem";
import { AddressText } from "@/components/text/address";

interface RosterProps {
  alive: Address[];
  graveyard: Address[];
  /// Highlighted as "you" if it appears in either list.
  self?: Address;
  /// Immune this round, if any — shown but not eliminable.
  immune?: Address;
}

/// The living and the dead, side by side.
///
/// The graveyard is not decoration: eliminated players become the jury that picks the winner, so
/// who is in it — and in what order they got there — is live strategic information.
export const Roster: FC<RosterProps> = ({ alive, graveyard, self, immune }) => (
  <div className="grid gap-6 md:grid-cols-2">
    <Column title="Still in" count={alive.length}>
      {alive.map((player) => (
        <PlayerRow
          key={player}
          player={player}
          isSelf={eq(player, self)}
          badge={eq(player, immune) ? "immune" : undefined}
        />
      ))}
    </Column>

    <Column title="Voted out" count={graveyard.length}>
      {graveyard.length === 0 ? (
        <p className="text-sm text-neutral-500">Nobody yet.</p>
      ) : (
        graveyard.map((player, i) => (
          <PlayerRow key={player} player={player} isSelf={eq(player, self)} rank={i + 1} eliminated />
        ))
      )}
    </Column>
  </div>
);

const Column: FC<{ title: string; count: number; children: React.ReactNode }> = ({ title, count, children }) => (
  <div className="box-border flex w-full flex-col gap-3 rounded-xl border border-neutral-100 bg-neutral-0 p-4 xl:p-6">
    <div className="flex items-baseline justify-between">
      <h2 className="text-lg font-semibold text-neutral-800">{title}</h2>
      <span className="text-sm text-neutral-500">{count}</span>
    </div>
    <div className="flex flex-col gap-2">{children}</div>
  </div>
);

const PlayerRow: FC<{
  player: Address;
  isSelf?: boolean;
  eliminated?: boolean;
  rank?: number;
  badge?: string;
}> = ({ player, isSelf, eliminated, rank, badge }) => (
  <div className="flex items-center justify-between gap-2 rounded-lg bg-neutral-50 px-3 py-2">
    <span className={eliminated ? "text-neutral-400 line-through" : "text-neutral-800"}>
      <AddressText>{player}</AddressText>
    </span>
    <span className="flex items-center gap-2 text-xs">
      {isSelf && <span className="rounded bg-primary-100 px-2 py-0.5 text-primary-700">you</span>}
      {badge && <span className="rounded bg-success-100 px-2 py-0.5 text-success-700">{badge}</span>}
      {rank !== undefined && <span className="text-neutral-400">#{rank}</span>}
    </span>
  </div>
);

function eq(a?: Address, b?: Address) {
  return !!a && !!b && a.toLowerCase() === b.toLowerCase();
}
