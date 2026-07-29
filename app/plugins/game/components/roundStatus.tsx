import { useEffect, useState, type FC } from "react";
import type { Round, RoundPhase } from "../utils/gameTypes";

interface RoundStatusProps {
  round: Round;
  tallyGrace: bigint;
}

const PHASE_COPY: Record<RoundPhase, { label: string; blurb: string }> = {
  campaign: {
    label: "Campaign",
    blurb: "Talk in public. Nothing you say here is binding — and everyone knows it.",
  },
  ballot: {
    label: "Ballot",
    blurb: "Votes are being cast, encrypted. Re-vote as often as you like; the last one counts.",
  },
  tally: {
    label: "Tally",
    blurb: "The committee is decrypting. Only the totals come back.",
  },
  settled: {
    label: "Settled",
    blurb: "The round is closed.",
  },
};

/// Round clock.
///
/// Rounds advance on wall-clock time, not on transactions, so this ticks locally rather than
/// waiting for an event that will never arrive.
export const RoundStatus: FC<RoundStatusProps> = ({ round, tallyGrace }) => {
  const now = useNow();
  const phase = derivePhase(round, now);
  const target = nextBoundary(round, phase, tallyGrace);
  const copy = PHASE_COPY[phase];

  return (
    <div className="box-border flex w-full flex-col gap-2 rounded-xl border border-neutral-100 bg-neutral-0 p-4 xl:p-6">
      <div className="flex items-baseline justify-between">
        <h2 className="text-lg font-semibold text-neutral-800">
          Round {round.id + 1} — {copy.label}
        </h2>
        {target !== undefined && target > now && (
          <span className="font-mono text-sm text-neutral-600">{formatCountdown(target - now)}</span>
        )}
      </div>
      <p className="text-sm text-neutral-500">{copy.blurb}</p>
    </div>
  );
};

function derivePhase(round: Round, now: bigint): RoundPhase {
  if (round.settled) return "settled";
  if (now < round.ballotOpensAt) return "campaign";
  if (now < round.ballotClosesAt) return "ballot";
  return "tally";
}

function nextBoundary(round: Round, phase: RoundPhase, tallyGrace: bigint): bigint | undefined {
  switch (phase) {
    case "campaign":
      return round.ballotOpensAt;
    case "ballot":
      return round.ballotClosesAt;
    case "tally":
      return round.ballotClosesAt + tallyGrace;
    default:
      return undefined;
  }
}

function formatCountdown(seconds: bigint): string {
  const total = Number(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return h > 0 ? `${h}h ${m}m` : m > 0 ? `${m}m ${s}s` : `${s}s`;
}

function useNow(): bigint {
  const [now, setNow] = useState(() => BigInt(Math.floor(Date.now() / 1000)));

  useEffect(() => {
    const id = setInterval(() => setNow(BigInt(Math.floor(Date.now() / 1000))), 1000);
    return () => clearInterval(id);
  }, []);

  return now;
}
