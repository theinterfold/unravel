import { useState, type FC } from "react";
import type { Address } from "viem";
import { Button } from "@aragon/ods";
import { AddressText } from "@/components/text/address";
import { useCastBallot } from "../hooks/useCastBallot";
import { useE3State } from "../hooks/useE3State";

interface BallotProps {
  e3Id: bigint;
  /// Ballot option index -> player. Order matters: it is the mapping the ciphertext is cast against.
  candidates: Address[];
  /// Whether the connected wallet is entitled to vote this round.
  canVote: boolean;
  self?: Address;
}

/// The private half of a round.
///
/// Two things are stated in the UI rather than left implicit, because both are mechanics a player
/// has to understand to play well: your ballot can be changed until the window closes, and masking
/// is what makes a promise about your vote unenforceable.
export const Ballot: FC<BallotProps> = ({ e3Id, candidates, canVote, self }) => {
  const [selected, setSelected] = useState<number | null>(null);
  const { castBallot, castMask, isLoading, votingStep, stepMessage, error } = useCastBallot();
  const { e3 } = useE3State(e3Id);

  const votable = candidates.filter((c) => !isSelf(c, self));

  // A vote is encrypted under the committee's key, so there is nothing to cast until it exists.
  // The window opening on a timer says nothing about whether the committee is ready, and letting
  // someone press the button early produces an opaque failure minutes into proof generation.
  const keyReady = e3?.keyPublished ?? false;
  const ready = canVote && keyReady;

  return (
    <div className="box-border flex w-full flex-col gap-4 rounded-xl border border-neutral-100 bg-neutral-0 p-4 xl:p-6">
      <div>
        <h2 className="text-lg font-semibold text-neutral-800">Your ballot</h2>
        <p className="text-sm text-neutral-500">
          Encrypted. Only the totals are ever revealed — nobody learns who you voted for. You can change your mind until
          the window closes; the last ballot counts.
        </p>
      </div>

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
        {candidates.map((candidate, index) => {
          const disabled = !ready || isLoading;
          const isMe = isSelf(candidate, self);

          return (
            <button
              key={candidate}
              onClick={() => setSelected(index)}
              disabled={disabled}
              className={`flex items-center justify-between rounded-lg border px-3 py-2 text-left transition ${
                selected === index
                  ? "border-primary-400 bg-primary-50"
                  : "border-neutral-100 bg-neutral-50 hover:border-neutral-200"
              } ${disabled ? "cursor-not-allowed opacity-50" : ""}`}
            >
              <span className="text-neutral-800">
                <AddressText asLink={false}>{candidate}</AddressText>
              </span>
              {isMe && <span className="text-xs text-neutral-400">that&apos;s you</span>}
            </button>
          );
        })}
      </div>

      {votable.length === 0 && <p className="text-sm text-neutral-500">No one to vote for.</p>}

      <div className="flex flex-wrap gap-2">
        <Button
          size="md"
          disabled={selected === null || !ready || isLoading}
          onClick={() => selected !== null && castBallot(selected, e3Id)}
        >
          {isLoading ? "Working..." : keyReady ? "Cast ballot" : "Waiting for the committee"}
        </Button>

        <Button size="md" variant="tertiary" disabled={!keyReady || isLoading} onClick={() => castMask(e3Id)}>
          Send a mask
        </Button>
      </div>

      {isLoading && (
        // Proving takes 45-90s in the browser. Without saying so, a stalled-looking button invites
        // a second click, and the wallet prompt that follows looks like a bug.
        <p className="text-xs text-neutral-400">
          Generating the zero-knowledge proof in your browser. This takes up to a minute or two — leave the page open.
        </p>
      )}

      <p className="text-xs text-neutral-400">
        A mask is a zero-vote dropped into someone else&apos;s slot. It changes no result, but it makes it impossible to
        prove which ciphertext was anyone&apos;s — which is what stops votes being bought.
      </p>

      {votingStep !== "idle" && (
        <p className={`text-sm ${votingStep === "error" ? "text-critical-600" : "text-neutral-600"}`}>{stepMessage}</p>
      )}
      {error && votingStep !== "error" && <p className="text-sm text-critical-600">{error}</p>}
    </div>
  );
};

function isSelf(candidate: Address, self?: Address) {
  return !!self && candidate.toLowerCase() === self.toLowerCase();
}
