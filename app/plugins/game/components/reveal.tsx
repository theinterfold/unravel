import type { FC } from "react";
import type { Address } from "viem";
import { RoundKind, votesOnTeams, type Round } from "../utils/gameTypes";
import { shortAddress, sameAddress, tribe } from "../utils/tribes";
import type { TallyOutcome } from "../hooks/useTally";

interface RevealProps {
  round: Round;
  outcome: TallyOutcome | undefined;
  self?: Address;
}

/// The decrypted counts, and what they did.
///
/// The bars slam in from zero, 120ms apart, in the order the contract emitted them — the only
/// motion in the game that carries information. Total ballots cast is stated *after* the reveal and
/// never before, because before decryption that number does not exist.
export const Reveal: FC<RevealProps> = ({ round, outcome, self }) => {
  if (!outcome) {
    return (
      <section className="un-panel un-stack">
        <div className="un-label-dim">Round {String(round.id + 1).padStart(2, "0")} · settled</div>
        <p className="un-fine">Reading the result from the chain…</p>
      </section>
    );
  }

  // A round nobody voted in is void: no mandate, no victim, and the next round re-runs it rather
  // than eliminating by array order.
  if (outcome.kind === "void" || outcome.kind === "aborted") {
    return (
      <section className="un-panel un-stack">
        <div className="un-label-dim">Round {String(round.id + 1).padStart(2, "0")} · no result</div>
        <h2 className="un-verdict">
          {outcome.kind === "void" ? (
            <>
              Nobody voted. The round is <em>void</em>.
            </>
          ) : (
            <>
              The round was <em>abandoned</em>.
            </>
          )}
        </h2>
        <p className="un-prose">
          {outcome.kind === "void"
            ? "No ballots were counted, so there is no mandate to act on. Nobody goes home, and the round runs again."
            : "The committee never returned a tally, so the round was closed without a result. Nobody goes home."}
        </p>
      </section>
    );
  }

  const counts = outcome.counts;
  const total = counts.reduce((a, b) => a + b, 0n);
  const max = counts.reduce((a, b) => (b > a ? b : a), 0n);
  const leaders = counts.filter((c) => c === max && c > 0n).length;
  const names = optionNames(round);

  return (
    <section className="un-panel un-stack">
      <div className="un-label-dim">Round {String(round.id + 1).padStart(2, "0")} · tally · decrypted</div>

      <h2 className="un-verdict">{verdict(round, outcome)}</h2>

      <div className="un-stack" style={{ gap: 14 }}>
        {counts.map((count, i) => {
          const lead = count === max && count > 0n;
          const width = max > 0n ? Number((count * 100n) / max) : 3;
          return (
            <div
              key={i}
              className={`un-tally-row ${lead ? "un-tally-lead" : count === 0n ? "un-tally-zero" : ""}`}
              style={{ animationDelay: `${i * 120}ms` }}
            >
              <div className="un-tally-head">
                <span className="un-tally-name" style={optionColor(round, i)}>
                  {names[i] ?? `OPTION ${i + 1}`}
                  {sameAddress(round.candidates[i], self) && !votesOnTeams(round) ? " · YOU" : ""}
                </span>
                <span className="un-tally-count">{count.toString()}</span>
              </div>
              <div className="un-tally-bar" style={{ width: `${Math.max(3, width)}%` }} />
            </div>
          );
        })}
      </div>

      <p className="un-fine">
        {total.toString()} ballot{total === 1n ? "" : "s"} counted.
        {leaders > 1 &&
          " Tied at the top — the winner was drawn from the tied options using the tally itself, so the draw is fixed and anyone can recompute it."}
      </p>
    </section>
  );
};

function verdict(round: Round, outcome: TallyOutcome) {
  if (outcome.kind === "council") {
    const t = tribe(outcome.team);
    return (
      <>
        {t?.name ?? `Team ${outcome.team}`} goes to <em>council</em>.
      </>
    );
  }
  if (outcome.kind === "eliminated") {
    if (round.kind === RoundKind.Jury) {
      return (
        <>
          {shortAddress(outcome.player)} <em>wins</em>.
        </>
      );
    }
    return (
      <>
        {shortAddress(outcome.player)} is <em>out</em>.
      </>
    );
  }
  return null;
}

/// Option labels, straight from the round's own arrays — the same arrays the ciphertext indexes
/// into, so a label can never drift from the slot it describes.
function optionNames(round: Round): string[] {
  return votesOnTeams(round)
    ? round.candidateTeams.map((t) => tribe(t)?.name ?? `TEAM ${t}`)
    : round.candidates.map((c) => shortAddress(c));
}

function optionColor(round: Round, index: number) {
  if (!votesOnTeams(round)) return undefined;
  const t = tribe(round.candidateTeams[index]);
  return t ? { color: t.color } : undefined;
}
