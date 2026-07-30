import type { FC, ReactNode } from "react";
import type { Address } from "viem";
import { shortAddress, sameAddress, tribe } from "../utils/tribes";

interface RosterProps {
  alive: Address[];
  graveyard: Address[];
  /// Team id per player. Zero once tribes have dissolved.
  teamOf: Record<string, number>;
  /// Highlighted as "you".
  self?: Address;
  /// The tribe currently condemned to a council round, if any.
  condemnedTeam?: number;
  /// True once the merge has happened — the roster stops being grouped.
  merged?: boolean;
  /// Empty seats still open in the lobby, if the game has not started.
  openSeats?: number;
}

/// The board.
///
/// Grouped by tribe before the merge, because tribe is the unit the tribal round votes on — a flat
/// list would hide the thing players are actually reasoning about. The graveyard is never grouped:
/// once you are out your tribe stops mattering, but the order you went does, since the jury is built
/// from it.
///
/// A player is a tribe bar, an address and a state. No avatars and no generated art — the address is
/// the face, and the bar runs full height so a roster reads like pieces on a board.
export const Roster: FC<RosterProps> = ({ alive, graveyard, teamOf, self, condemnedTeam, merged, openSeats = 0 }) => {
  const groups = new Map<number, Address[]>();
  for (const player of alive) {
    const team = merged ? 0 : (teamOf[player.toLowerCase()] ?? 0);
    if (!groups.has(team)) groups.set(team, []);
    groups.get(team)!.push(player);
  }
  const grouped = [...groups.entries()].sort((a, b) => a[0] - b[0]);

  return (
    <div className="un-grid-2">
      <section className="un-panel un-stack" style={{ gap: 14 }}>
        <div className="un-spread">
          <div className="un-label-dim">The board · {alive.length} alive</div>
        </div>

        {grouped.map(([team, members]) => {
          const t = tribe(team);
          return (
            <div key={team} className="un-stack" style={{ gap: 8 }}>
              {t && (
                <div className="un-row" style={{ gap: 10 }}>
                  <span className="un-piece-tribe" style={{ color: t.color }}>
                    {t.name}
                  </span>
                  {team === condemnedTeam && <span className="un-tag un-tag-block">AT COUNCIL</span>}
                  <span className="un-mono" style={{ marginLeft: "auto", fontSize: 11 }}>
                    {members.length}
                  </span>
                </div>
              )}
              {members.map((player) => (
                <Piece
                  key={player}
                  player={player}
                  team={team}
                  you={sameAddress(player, self)}
                  onTheBlock={team !== 0 && team === condemnedTeam}
                />
              ))}
            </div>
          );
        })}

        {Array.from({ length: openSeats }, (_, i) => (
          <div key={`seat-${i}`} className="un-piece un-piece-open">
            <div className="un-piece-body">
              <span className="un-piece-addr" style={{ color: "var(--un-dim-2)" }}>
                seat open
              </span>
              <span className="un-piece-state">LOBBY</span>
            </div>
          </div>
        ))}
      </section>

      <section className="un-panel un-stack" style={{ gap: 14 }}>
        <div className="un-label-dim">The jury · {graveyard.length} seated</div>
        {graveyard.length === 0 ? (
          <p className="un-fine">Nobody yet.</p>
        ) : (
          <>
            {graveyard.map((player, i) => (
              <Piece
                key={player}
                player={player}
                team={teamOf[player.toLowerCase()] ?? 0}
                you={sameAddress(player, self)}
                out={i + 1}
              />
            ))}
            <p className="un-fine">
              Being voted out is not the end of your game. These are the jury, and they choose the winner.
            </p>
          </>
        )}
      </section>
    </div>
  );
};

const Piece: FC<{
  player: Address;
  team: number;
  you?: boolean;
  out?: number;
  onTheBlock?: boolean;
}> = ({ player, team, you, out, onTheBlock }) => {
  const t = tribe(team);
  const eliminated = out !== undefined;

  let state: ReactNode = <span>ALIVE</span>;
  if (eliminated) state = <span className="un-tag un-tag-jury">JURY</span>;
  else if (you) state = <span className="un-tag un-tag-you">YOU</span>;
  else if (onTheBlock) state = <span className="un-tag un-tag-block">ON THE BLOCK</span>;

  return (
    <div
      className={`un-piece ${eliminated ? "un-piece-out" : onTheBlock ? "un-piece-block" : you ? "un-piece-you" : ""}`}
    >
      <span
        className="un-piece-bar"
        style={{ background: eliminated ? undefined : onTheBlock ? "var(--un-condemned)" : t?.color }}
        aria-hidden="true"
      />
      <div className="un-piece-body">
        <span className="un-piece-addr">{shortAddress(player)}</span>
        {t && (
          <span className="un-piece-tribe" style={{ color: eliminated ? "var(--un-dim-2)" : t.color }}>
            {t.name}
            {/* Elimination order, not a round number: the jury array is ordered by when players
                went, and a forfeit can remove someone in the same round as a vote. */}
            {eliminated ? ` · OUT #${out}` : ""}
          </span>
        )}
        <span className="un-piece-state">{state}</span>
      </div>
    </div>
  );
};
