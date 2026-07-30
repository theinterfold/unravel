import { useState, type FC } from "react";
import type { Address } from "viem";
import { Button } from "@aragon/ods";
import { AddressText } from "@/components/text/address";
import { useCastBallot } from "../hooks/useCastBallot";
import { useE3State } from "../hooks/useE3State";
import { RoundKind, votesOnTeams, type Round } from "../utils/gameTypes";

interface BallotProps {
  round: Round;
  /// Whether the connected wallet is in this round's voter set.
  canVote: boolean;
  self?: Address;
}

const COPY: Record<RoundKind, { title: string; blurb: string }> = {
  [RoundKind.Tribal]: {
    title: "Which team goes to council",
    blurb:
      "Everyone alive votes. The team with the most votes has to vote one of its own out — you are choosing who has to bleed, not who dies.",
  },
  [RoundKind.Council]: {
    title: "Which of you goes",
    blurb: "Only your team votes now. One of the names below will not be here next round.",
  },
  [RoundKind.Individual]: {
    title: "Who goes",
    blurb: "Teams are gone. Everyone alive votes to eliminate one player.",
  },
  [RoundKind.Jury]: {
    title: "Who wins",
    blurb: "The eliminated decide. Pick a finalist.",
  },
};

/// The private half of a round.
///
/// The options are teams in a tribal round and players everywhere else, so the option index means
/// different things in different rounds — and it is the index, not the label, that the ciphertext is
/// cast against. Rendering straight from the round's own arrays keeps the two in step.
export const Ballot: FC<BallotProps> = ({ round, canVote, self }) => {
  const [selected, setSelected] = useState<number | null>(null);
  const { castBallot, castMask, isLoading, votingStep, stepMessage, error } = useCastBallot();
  const { e3 } = useE3State(round.e3Id);

  // A vote is encrypted under the committee's key, so there is nothing to cast until it exists.
  // The window opening on a timer says nothing about whether the committee is ready, and letting
  // someone press the button early produces an opaque failure minutes into proof generation.
  const keyReady = e3?.keyPublished ?? false;
  const ready = canVote && keyReady;
  const copy = COPY[round.kind];
  const onTeams = votesOnTeams(round);

  return (
    <div className="box-border flex w-full flex-col gap-4 rounded-xl border border-neutral-100 bg-neutral-0 p-4 xl:p-6">
      <div>
        <h2 className="text-lg font-semibold text-neutral-800">{copy.title}</h2>
        <p className="text-sm text-neutral-500">{copy.blurb}</p>
      </div>

      <p className="text-sm text-neutral-500">
        Encrypted. Only the totals are ever revealed — nobody learns what you chose. You can change your mind until the
        window closes; the last ballot counts.
      </p>

      {!keyReady && (
        <div className="flex items-start gap-2 rounded-lg bg-warning-100 p-3 text-sm text-neutral-700">
          <span className="mt-1.5 h-2 w-2 shrink-0 animate-pulse rounded-full bg-warning-500" />
          <span>
            The committee has not published its key yet, so there is nothing to encrypt against. Voting unlocks
            automatically once it does — usually a few minutes after the round opens.
          </span>
        </div>
      )}

      <div className="flex flex-col gap-2">
        {onTeams
          ? round.candidateTeams.map((team, index) => (
              <Option
                key={`team-${team}`}
                label={`Team ${team}`}
                selected={selected === index}
                disabled={!ready || isLoading}
                onSelect={() => setSelected(index)}
              />
            ))
          : round.candidates.map((candidate, index) => (
              <Option
                key={candidate}
                label={<AddressText asLink={false}>{candidate}</AddressText>}
                note={self && candidate.toLowerCase() === self.toLowerCase() ? "that's you" : undefined}
                selected={selected === index}
                disabled={!ready || isLoading}
                onSelect={() => setSelected(index)}
              />
            ))}
      </div>

      <div className="flex flex-wrap gap-2">
        <Button
          size="md"
          disabled={selected === null || !ready || isLoading}
          onClick={() => selected !== null && castBallot(selected, round.e3Id)}
        >
          {isLoading ? "Working..." : keyReady ? "Cast ballot" : "Waiting for the committee"}
        </Button>

        <Button size="md" variant="tertiary" disabled={!keyReady || isLoading} onClick={() => castMask(round.e3Id)}>
          Send a mask
        </Button>
      </div>

      <p className="text-xs text-neutral-400">
        A mask is a zero-vote dropped into someone else&apos;s slot. It changes no result, but it makes it impossible to
        prove which ciphertext was anyone&apos;s — which is what stops votes being bought.
      </p>

      {isLoading && (
        // Proving takes 45-90s in the browser. Without saying so, a stalled-looking button invites
        // a second click, and the wallet prompt that follows looks like a bug.
        <p className="text-xs text-neutral-400">
          Generating the zero-knowledge proof in your browser. This takes up to a minute or two — leave the page open.
        </p>
      )}

      {votingStep !== "idle" && (
        <p className={`text-sm ${votingStep === "error" ? "text-critical-600" : "text-neutral-600"}`}>{stepMessage}</p>
      )}
      {error && votingStep !== "error" && <p className="text-sm text-critical-600">{error}</p>}
    </div>
  );
};

const Option: FC<{
  label: React.ReactNode;
  note?: string;
  selected: boolean;
  disabled: boolean;
  onSelect: () => void;
}> = ({ label, note, selected, disabled, onSelect }) => (
  <button
    onClick={onSelect}
    disabled={disabled}
    className={`flex items-center justify-between rounded-lg border px-3 py-2 text-left transition ${
      selected ? "border-primary-400 bg-primary-50" : "border-neutral-100 bg-neutral-50 hover:border-neutral-200"
    } ${disabled ? "cursor-not-allowed opacity-50" : ""}`}
  >
    <span className="text-neutral-800">{label}</span>
    {note && <span className="text-xs text-neutral-400">{note}</span>}
  </button>
);
