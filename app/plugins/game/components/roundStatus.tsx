import { useEffect, useState, type FC } from "react";
import type { Round, RoundPhase } from "../utils/gameTypes";
import { useE3State } from "../hooks/useE3State";

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
    blurb: "The committee is decrypting. Only the totals come back — never who cast what.",
  },
  settled: {
    label: "Settled",
    blurb: "The round is closed.",
  },
};

/// Round clock and E3 state.
///
/// Rounds advance on wall-clock time, not on transactions, so the countdown ticks locally rather
/// than waiting for an event that will never arrive.
///
/// The committee-key line is the important part. A round opens its ballot window on a timer, but a
/// vote cannot be encrypted until the committee has published its key — which takes minutes. Without
/// showing that, the UI presents an open ballot that silently rejects every vote, and the only
/// symptom is failure.
export const RoundStatus: FC<RoundStatusProps> = ({ round, tallyGrace }) => {
  const now = useNow();
  const { e3, unavailable } = useE3State(round.e3Id);

  const phase = derivePhase(round, now);
  const target = nextBoundary(round, phase, tallyGrace);
  const copy = PHASE_COPY[phase];

  const settleAt = round.ballotClosesAt + tallyGrace;
  const elapsed = Number(now - round.openedAt);
  const total = Number(settleAt - round.openedAt);
  const progress = total > 0 ? Math.min(100, Math.max(0, (elapsed / total) * 100)) : 0;

  return (
    <div className="box-border flex w-full flex-col gap-4 rounded-xl border border-neutral-100 bg-neutral-0 p-4 xl:p-6">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-lg font-semibold text-neutral-800">
          Round {round.id + 1} — {copy.label}
        </h2>
        {target !== undefined && target > now ? (
          <span className="font-mono text-sm text-neutral-700">{formatCountdown(target - now)} left</span>
        ) : (
          phase === "tally" && <span className="text-sm text-neutral-500">awaiting the tally</span>
        )}
      </div>

      <p className="text-sm text-neutral-500">{copy.blurb}</p>

      {/* Where this round sits between opening and settlement. */}
      <div>
        <div className="h-1.5 w-full overflow-hidden rounded bg-neutral-100">
          <div className="h-1.5 rounded bg-primary-500 transition-all" style={{ width: `${progress}%` }} />
        </div>
        <div className="mt-2 grid grid-cols-3 gap-2 text-xs">
          <Marker label="Campaign" at={round.openedAt} active={phase === "campaign"} done={now >= round.ballotOpensAt} />
          <Marker label="Ballot" at={round.ballotOpensAt} active={phase === "ballot"} done={now >= round.ballotClosesAt} />
          <Marker label="Tally" at={round.ballotClosesAt} active={phase === "tally"} done={round.settled} />
        </div>
      </div>

      {/* Committee readiness — the thing that actually gates voting. */}
      {!round.settled && (
        <div className="flex flex-col gap-2 rounded-lg bg-neutral-50 p-3 text-sm">
          {unavailable && !e3 && <Line tone="muted" text="Waiting for the coordination server to pick up this round…" />}

          {e3 && !e3.keyPublished && (
            <Line
              tone="warn"
              text="The committee is still generating its key. Voting is impossible until it publishes — this normally takes a few minutes."
            />
          )}

          {e3?.keyPublished && phase === "campaign" && (
            <Line tone="ok" text="Committee key published. Ballots open when the campaign ends." />
          )}

          {e3?.keyPublished && phase === "ballot" && <Line tone="ok" text="Committee key published. Ballots are open." />}

          {e3 && (
            <div className="flex flex-wrap gap-x-6 gap-y-1 text-xs text-neutral-500">
              <span>
                E3 <span className="font-mono text-neutral-700">#{round.e3Id.toString()}</span>
              </span>
              <span>
                ballots cast <span className="font-mono text-neutral-700">{e3.voteCount}</span>
              </span>
              <span>
                round state <span className="font-mono text-neutral-700">{e3.status}</span>
              </span>
            </div>
          )}
        </div>
      )}

      <dl className="grid grid-cols-2 gap-x-6 gap-y-1 text-xs text-neutral-500 sm:grid-cols-4">
        <Stat label="Opened" value={formatClock(round.openedAt)} />
        <Stat label="Ballot opens" value={formatClock(round.ballotOpensAt)} />
        <Stat label="Ballot closes" value={formatClock(round.ballotClosesAt)} />
        <Stat label="Settles from" value={formatClock(settleAt)} />
      </dl>
    </div>
  );
};

const Marker: FC<{ label: string; at: bigint; active: boolean; done: boolean }> = ({ label, at, active, done }) => (
  <div className={active ? "text-primary-700" : done ? "text-neutral-400" : "text-neutral-500"}>
    <div className={active ? "font-semibold" : ""}>{label}</div>
    <div className="font-mono">{formatClock(at)}</div>
  </div>
);

const Stat: FC<{ label: string; value: string }> = ({ label, value }) => (
  <div>
    <dt>{label}</dt>
    <dd className="font-mono text-neutral-700">{value}</dd>
  </div>
);

const Line: FC<{ tone: "ok" | "warn" | "muted"; text: string }> = ({ tone, text }) => {
  const dot = tone === "ok" ? "bg-success-500" : tone === "warn" ? "bg-warning-500" : "bg-neutral-300";
  const fg = tone === "warn" ? "text-neutral-700" : "text-neutral-600";
  return (
    <div className="flex items-start gap-2">
      <span className={`mt-1.5 h-2 w-2 shrink-0 rounded-full ${dot} ${tone === "warn" ? "animate-pulse" : ""}`} />
      <span className={fg}>{text}</span>
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
  if (h > 0) return `${h}h ${String(m).padStart(2, "0")}m`;
  if (m > 0) return `${m}m ${String(s).padStart(2, "0")}s`;
  return `${s}s`;
}

function formatClock(unixSeconds: bigint): string {
  if (unixSeconds === 0n) return "—";
  return new Date(Number(unixSeconds) * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function useNow(): bigint {
  const [now, setNow] = useState(() => BigInt(Math.floor(Date.now() / 1000)));

  useEffect(() => {
    const id = setInterval(() => setNow(BigInt(Math.floor(Date.now() / 1000))), 1000);
    return () => clearInterval(id);
  }, []);

  return now;
}
