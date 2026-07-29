import { useState, type FC } from "react";
import type { Address } from "viem";
import { Button } from "@aragon/ods";
import { AddressText } from "@/components/text/address";
import { useCastBallot } from "../hooks/useCastBallot";

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

  const votable = candidates.filter((c) => !isSelf(c, self));

  return (
    <div className="box-border flex w-full flex-col gap-4 rounded-xl border border-neutral-100 bg-neutral-0 p-4 xl:p-6">
      <div>
        <h2 className="text-lg font-semibold text-neutral-800">Your ballot</h2>
        <p className="text-sm text-neutral-500">
          Encrypted. Only the totals are ever revealed — nobody learns who you voted for. You can change your mind until
          the window closes; the last ballot counts.
        </p>
      </div>

      <div className="flex flex-col gap-2">
        {candidates.map((candidate, index) => {
          const disabled = !canVote || isLoading;
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
          disabled={selected === null || !canVote || isLoading}
          onClick={() => selected !== null && castBallot(selected, e3Id)}
        >
          {isLoading ? "Working..." : "Cast ballot"}
        </Button>

        <Button size="md" variant="tertiary" disabled={isLoading} onClick={() => castMask(e3Id)}>
          Send a mask
        </Button>
      </div>

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
