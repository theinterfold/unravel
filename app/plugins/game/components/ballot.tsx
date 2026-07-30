import { useEffect, useState, type FC } from "react";
import type { Address } from "viem";
import { useCastBallot } from "../hooks/useCastBallot";
import { useE3State } from "../hooks/useE3State";
import { RoundKind, votesOnTeams, type Round } from "../utils/gameTypes";
import { shortAddress, sameAddress, tribe } from "../utils/tribes";
import { Sealing } from "./sealing";

interface BallotProps {
  round: Round;
  /// Whether the connected wallet is in this round's voter set and the window is open.
  canVote: boolean;
  self?: Address;
  /// Called once a ballot is accepted, so the shell can stop telling this browser it owes a vote.
  onSealed?: () => void;
}

const COPY: Record<RoundKind, { title: string; blurb: string }> = {
  [RoundKind.Tribal]: {
    title: "Vote for a tribe",
    blurb:
      "The tribe with the most votes has to vote one of its own out. You are choosing who has to bleed, not who dies.",
  },
  [RoundKind.Council]: {
    title: "Vote for one of your own",
    blurb: "Only your tribe votes now. One of the names below will not be here next round.",
  },
  [RoundKind.Individual]: {
    title: "Vote someone out",
    blurb: "Tribes are gone. Everyone alive votes to eliminate one player.",
  },
  [RoundKind.Jury]: {
    title: "Vote for the winner",
    blurb: "The eliminated decide. Pick a finalist.",
  },
};

/// The private half of a round.
///
/// The options are tribes in a tribal round and players everywhere else, so the option index means
/// different things in different rounds — and it is the index, not the label, that the ciphertext is
/// cast against. Rendering straight from the round's own arrays keeps the two in step.
export const Ballot: FC<BallotProps> = ({ round, canVote, self, onSealed }) => {
  const [selected, setSelected] = useState<number | null>(null);
  const { castBallot, castMask, isLoading, votingStep, stepMessage, error, txHash } = useCastBallot();
  const { e3 } = useE3State(round.e3Id);

  // A vote is encrypted under the committee's key, so there is nothing to cast until it exists. The
  // window opening on a timer says nothing about whether the committee is ready, and letting someone
  // press the button early produces an opaque failure a minute into proof generation.
  const keyReady = e3?.keyPublished ?? false;
  const ready = canVote && keyReady && !isLoading;
  const copy = COPY[round.kind];
  const onTribes = votesOnTeams(round);
  const sealed = votingStep === "complete";

  // Report upward exactly once per acceptance. The chain cannot confirm this for us — a sealed
  // ballot is indistinguishable from a mask — so the client's own success is the only signal there
  // is.
  useEffect(() => {
    if (sealed) onSealed?.();
  }, [sealed, onSealed]);

  return (
    <section className="un-panel un-stack">
      <div>
        <h2 className="un-title">{copy.title}</h2>
        <p className="un-note" style={{ marginTop: 6, maxWidth: "62ch" }}>
          {copy.blurb}
        </p>
      </div>

      {/* Green, not red. Waiting on the committee is a normal state of a distributed system, and
          this copy's only job is: nothing is broken and you are not late. The options render
          underneath regardless, so a player can decide while they wait. */}
      {!keyReady && (
        <div className="un-waiting">
          <div className="un-waiting-head">
            <span className="un-waiting-dot" aria-hidden="true" />
            <span className="un-waiting-title">Waiting on the committee</span>
          </div>
          <p className="un-note">
            Independent nodes each publish a share of the encryption key. Voting opens the second the last one lands — a
            few minutes, usually. Nothing is wrong and you are not late.
          </p>
        </div>
      )}

      <div className="un-stack" style={{ gap: 8 }}>
        {onTribes
          ? round.candidateTeams.map((team, index) => {
              const t = tribe(team);
              return (
                <Option
                  key={`team-${team}`}
                  name={t?.name ?? `TEAM ${team}`}
                  color={t?.color}
                  selected={selected === index}
                  disabled={!ready}
                  onSelect={() => setSelected(index)}
                />
              );
            })
          : round.candidates.map((candidate, index) => (
              <Option
                key={candidate}
                name={shortAddress(candidate)}
                note={sameAddress(candidate, self) ? "THAT'S YOU" : undefined}
                selected={selected === index}
                disabled={!ready}
                onSelect={() => setSelected(index)}
              />
            ))}
      </div>

      {/* The sealing state replaces the controls entirely while it runs: there is nothing useful to
          press, and leaving a live button next to a minute of work invites a second click. */}
      {(isLoading || sealed || votingStep === "error") && (
        <Sealing step={votingStep} message={stepMessage} txHash={txHash} />
      )}

      {!isLoading && (
        <>
          <div className="un-row">
            <button
              type="button"
              className="un-btn"
              disabled={selected === null || !ready}
              onClick={() => selected !== null && castBallot(selected, round.e3Id)}
            >
              {sealed ? "Change your vote" : keyReady ? "Seal your ballot" : "Waiting for the committee"}
            </button>

            <button
              type="button"
              className="un-btn un-btn-ghost"
              disabled={!keyReady || isLoading}
              onClick={() => castMask(round.e3Id)}
            >
              Send a mask
            </button>
          </div>

          <p className="un-fine" style={{ maxWidth: "72ch" }}>
            {sealed
              ? "Sealing again replaces what you sent — the last ballot before the window closes is the one that counts. It costs another 45–90 seconds."
              : "Sealing takes 45–90 seconds in your browser. You can change your vote until the window closes; the last one counts."}{" "}
            A mask is a zero-vote dropped into someone else&apos;s slot. It changes no result, but it makes it
            impossible to prove which sealed ballot was anyone&apos;s — which is what stops votes being bought.
          </p>
        </>
      )}

      {error && votingStep !== "error" && (
        <div className="un-error" role="alert">
          {error}
        </div>
      )}
    </section>
  );
};

const Option: FC<{
  name: string;
  color?: string;
  note?: string;
  selected: boolean;
  disabled: boolean;
  onSelect: () => void;
}> = ({ name, color, note, selected, disabled, onSelect }) => (
  <button
    type="button"
    onClick={onSelect}
    disabled={disabled}
    aria-pressed={selected}
    className={`un-option ${selected ? "un-option-on" : ""}`}
    style={color ? { borderLeftColor: color } : undefined}
  >
    <span className="un-option-name" style={color ? { color, fontWeight: 700, letterSpacing: ".1em" } : undefined}>
      {name}
    </span>
    {note && <span className="un-option-note">{note}</span>}
  </button>
);
