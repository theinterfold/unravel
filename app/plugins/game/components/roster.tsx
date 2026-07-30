import type { FC } from "react";
import type { Address } from "viem";
import { AddressText } from "@/components/text/address";

interface RosterProps {
  alive: Address[];
  graveyard: Address[];
  /// Team id per player. Zero once teams have dissolved.
  teamOf: Record<string, number>;
  /// Highlighted as "you".
  self?: Address;
  /// The team currently condemned to a council round, if any.
  condemnedTeam?: number;
  /// True once the merge has happened — the roster stops being grouped.
  merged?: boolean;
}

/// The living and the dead.
///
/// Grouped by team before the merge, because team is the unit the tribal round votes on — a flat
/// list would hide the thing players are actually reasoning about. The graveyard is never grouped:
/// once you are out, your team no longer matters, but the order you went does, since the jury is
/// built from it.
export const Roster: FC<RosterProps> = ({ alive, graveyard, teamOf, self, condemnedTeam, merged }) => {
  const teams = new Map<number, Address[]>();
  for (const player of alive) {
    const team = merged ? 0 : (teamOf[player.toLowerCase()] ?? 0);
    if (!teams.has(team)) teams.set(team, []);
    teams.get(team)!.push(player);
  }
  const grouped = [...teams.entries()].sort((a, b) => a[0] - b[0]);

  return (
    <div className="grid gap-6 md:grid-cols-2">
      <div className="box-border flex w-full flex-col gap-3 rounded-xl border border-neutral-100 bg-neutral-0 p-4 xl:p-6">
        <div className="flex items-baseline justify-between">
          <h2 className="text-lg font-semibold text-neutral-800">Still in</h2>
          <span className="text-sm text-neutral-500">{alive.length}</span>
        </div>

        {grouped.map(([team, members]) => (
          <div key={team} className="flex flex-col gap-2">
            {team !== 0 && (
              <div className="flex items-baseline gap-2">
                <span className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Team {team}</span>
                {team === condemnedTeam && (
                  <span className="rounded bg-critical-100 px-2 py-0.5 text-xs text-critical-700">at council</span>
                )}
                <span className="text-xs text-neutral-400">{members.length}</span>
              </div>
            )}
            {members.map((player) => (
              <PlayerRow key={player} player={player} isSelf={eq(player, self)} />
            ))}
          </div>
        ))}
      </div>

      <div className="box-border flex w-full flex-col gap-3 rounded-xl border border-neutral-100 bg-neutral-0 p-4 xl:p-6">
        <div className="flex items-baseline justify-between">
          <h2 className="text-lg font-semibold text-neutral-800">Voted out</h2>
          <span className="text-sm text-neutral-500">{graveyard.length}</span>
        </div>
        {graveyard.length === 0 ? (
          <p className="text-sm text-neutral-500">Nobody yet.</p>
        ) : (
          <>
            {graveyard.map((player, i) => (
              <PlayerRow key={player} player={player} isSelf={eq(player, self)} rank={i + 1} eliminated />
            ))}
            <p className="text-xs text-neutral-400">These are the jury. They decide the winner.</p>
          </>
        )}
      </div>
    </div>
  );
};

const PlayerRow: FC<{
  player: Address;
  isSelf?: boolean;
  eliminated?: boolean;
  rank?: number;
}> = ({ player, isSelf, eliminated, rank }) => (
  <div className="flex items-center justify-between gap-2 rounded-lg bg-neutral-50 px-3 py-2">
    <span className={eliminated ? "text-neutral-400 line-through" : "text-neutral-800"}>
      <AddressText>{player}</AddressText>
    </span>
    <span className="flex items-center gap-2 text-xs">
      {isSelf && <span className="rounded bg-primary-100 px-2 py-0.5 text-primary-700">you</span>}
      {rank !== undefined && <span className="text-neutral-400">#{rank}</span>}
    </span>
  </div>
);

function eq(a?: Address, b?: Address) {
  return !!a && !!b && a.toLowerCase() === b.toLowerCase();
}
