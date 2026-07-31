import { useEffect, useState, type FC, type ReactNode } from "react";
import { RoundKind, type Round, type RoundPhase } from "../utils/gameTypes";
import { ROUND_BADGE, ROUND_RULE, formatClock, formatCountdown } from "../utils/tribes";
import { useE3State } from "../hooks/useE3State";

interface RoundStatusProps {
  round: Round;
  tallyGrace: bigint;
  /// True once the decrypted counts are on chain. Changes what the spent clock means: waiting on the
  /// committee is not the same as waiting on somebody to press a button.
  tallyReady?: boolean;
  /// Whether the connected player still owes an action this round. Drives the only alarm state the
  /// clock has — see below.
  owes?: boolean;
}

const PHASE_COPY: Record<RoundPhase, string> = {
  campaign: "Talk in public. Nothing you say here is binding — and everyone knows it.",
  ballot: "Votes are being cast, sealed. Re-vote as often as you like; the last one counts.",
  tally: "The committee is decrypting. Only the totals come back — never who cast what.",
  settled: "The round is closed.",
};

/// The persistent frame: which round, which kind, which phase, and how long is left.
///
/// The clock counts the current phase only. A player should never have to do arithmetic, and the
/// three-segment track exists so the phases they are *not* in stay visible without competing.
///
/// The clock only panics if the player still owes something. Voted and checked in? It stays green
/// and quiet while everyone else sweats — that asymmetry is the reward for being organised, and it
/// keeps the red state meaning exactly one thing.
export const RoundStatus: FC<RoundStatusProps> = ({ round, tallyGrace, owes = false, tallyReady = false }) => {
  const now = useNow();
  const { e3, unavailable } = useE3State(round.e3Id);

  const phase = derivePhase(round, now);
  const target = nextBoundary(round, phase, tallyGrace);
  const remaining = target !== undefined && target > now ? target - now : 0n;
  const rush = owes && remaining > 0n && remaining <= 90n;
  const badge = ROUND_BADGE[round.kind];

  return (
    <section className="un-panel un-stack">
      <div className="un-spread">
        <div>
          <div className="un-label">
            Round {String(round.id + 1).padStart(2, "0")} · {badge.name}
          </div>
          <p className="un-note" style={{ marginTop: 6, maxWidth: "62ch" }}>
            {ROUND_RULE[round.kind]}
          </p>
        </div>
        <RoundMark kind={round.kind} />
      </div>

      <div className="un-track">
        <Segment
          name="Campaign"
          live={phase === "campaign"}
          done={now >= round.ballotOpensAt}
          value={
            phase === "campaign" ? "OPEN NOW" : now >= round.ballotOpensAt ? "CLOSED" : formatClock(round.openedAt)
          }
        />
        <Segment
          name="Ballot"
          live={phase === "ballot"}
          done={now >= round.ballotClosesAt}
          value={
            phase === "ballot" ? "OPEN NOW" : now >= round.ballotClosesAt ? "CLOSED" : formatClock(round.ballotOpensAt)
          }
        />
        <Segment
          name="Tally"
          live={phase === "tally"}
          done={round.settled}
          value={round.settled ? "SETTLED" : phase === "tally" ? "DECRYPTING" : formatClock(round.ballotClosesAt)}
        />
      </div>

      {!round.settled && (
        <div>
          <div
            className={`un-clock ${owes ? "un-clock-owed" : ""} ${rush ? "un-clock-rush" : ""}`}
            // Announced politely: a countdown that interrupts a screen reader every second is worse
            // than one that is never announced at all.
            role="timer"
            aria-live="off"
          >
            {remaining > 0n ? formatCountdown(remaining) : spentLabel(phase, tallyReady)}
          </div>
          <div className={`un-clock-cap ${owes ? "un-clock-cap-owed" : ""}`}>
            {phaseCaption(phase, owes, rush, remaining, tallyReady)}
          </div>
        </div>
      )}

      <p className="un-fine">{PHASE_COPY[phase]}</p>

      {/* The committee is what actually gates voting. A ballot window opening on a timer says
          nothing about whether a vote can be encrypted yet. */}
      {!round.settled && (
        <>
          {unavailable && !e3 && <Line tone="wait" text="Waiting for the coordination server to pick up this round." />}
          {e3 && !e3.keyPublished && (
            <Line
              tone="wait"
              text="The committee is still generating its key. Nothing can be sealed until it publishes — usually a few minutes."
            />
          )}
          {e3?.keyPublished && (
            <Line
              tone="ok"
              text={
                phase === "campaign"
                  ? "Committee key published. Ballots open when the campaign ends."
                  : "Committee key published. Ballots are open."
              }
            />
          )}
        </>
      )}

      <div className="un-row" style={{ gap: 22, borderTop: "1px solid var(--un-line)", paddingTop: 14 }}>
        <Fact label="E3" value={`#${round.e3Id.toString()}`} />
        <Fact label="Ballot closes" value={formatClock(round.ballotClosesAt)} />
        <Fact label="Settles from" value={formatClock(round.ballotClosesAt + tallyGrace)} />
        {/* Deliberately absent: how many have voted. Before decryption that number does not exist,
            and showing the server's running count would imply the ballot is observable. */}
      </div>
    </section>
  );
};

const Segment: FC<{ name: string; value: string; live: boolean; done: boolean }> = ({ name, value, live, done }) => (
  <div className={`un-seg ${live ? "un-seg-live" : done ? "un-seg-done" : ""}`}>
    <div className="un-seg-name">{name}</div>
    <div className="un-seg-val">{value}</div>
  </div>
);

const Fact: FC<{ label: string; value: string }> = ({ label, value }) => (
  <div>
    <div className="un-label-dim" style={{ fontSize: 10 }}>
      {label}
    </div>
    <div className="un-mono" style={{ color: "var(--un-fg-2)", marginTop: 3 }}>
      {value}
    </div>
  </div>
);

const Line: FC<{ tone: "ok" | "wait"; text: string }> = ({ tone, text }) => (
  <div className="un-row" style={{ gap: 10, flexWrap: "nowrap", alignItems: "flex-start" }}>
    <span
      style={{
        marginTop: 5,
        width: 10,
        height: 10,
        flex: "0 0 auto",
        borderRadius: "50%",
        border: `2.5px solid ${tone === "ok" ? "var(--un-green)" : "var(--un-pistachio)"}`,
        background: tone === "ok" ? "var(--un-green)" : "transparent",
        animation: tone === "wait" ? "un-breathe 1.8s ease-in-out infinite" : undefined,
      }}
    />
    <span className="un-note">{text}</span>
  </div>
);

/// The five round marks. Only COUNCIL is framed in red — somebody is definitely dying — and the
/// design reserves the same treatment in pistachio for a public immunity round, which this build
/// does not run.
const RoundMark: FC<{ kind: RoundKind }> = ({ kind }) => {
  const badge = ROUND_BADGE[kind];
  return (
    <div className={`un-badge ${kind === RoundKind.Council ? "un-badge-council" : ""}`}>
      <div className="un-badge-mark">
        <Mark kind={kind} />
      </div>
      <div className="un-badge-name">{badge.name}</div>
      <div className="un-badge-rule">{badge.hint}</div>
    </div>
  );
};

const Mark: FC<{ kind: RoundKind }> = ({ kind }): ReactNode => {
  const sq = (bg: string, size = 12) => (
    <span style={{ width: size, height: size, background: bg, display: "block" }} />
  );

  switch (kind) {
    case RoundKind.Tribal: // four tribes, one about to go dark
      return (
        <span style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 3 }}>
          {sq("var(--un-fg)")}
          {sq("var(--un-fg)")}
          {sq("var(--un-fg)")}
          {sq("var(--un-dim)")}
        </span>
      );
    case RoundKind.Council: // three, and the middle one goes
      return (
        <span style={{ display: "flex", gap: 3 }}>
          <span style={{ width: 12, height: 12, border: "2px solid var(--un-condemned)" }} />
          {sq("var(--un-condemned)")}
          <span style={{ width: 12, height: 12, border: "2px solid var(--un-condemned)" }} />
        </span>
      );
    case RoundKind.Individual: // no tribes left, just a person
      return <span style={{ width: 20, height: 20, background: "var(--un-fg)", borderRadius: "50%" }} />;
    case RoundKind.Jury: // the dead, in a row
      return (
        <span style={{ display: "flex", gap: 3 }}>
          {[0, 1, 2, 3, 4].map((i) => (
            <span key={i} style={{ width: 7, height: 7, background: "var(--un-sage)", borderRadius: "50%" }} />
          ))}
        </span>
      );
  }
};

/// What the big number says once there is nothing left to count down.
///
/// A spent clock showing an em dash reads as broken. The round is not stalled at that point — it is
/// waiting on a transaction anyone can send.
function spentLabel(phase: RoundPhase, tallyReady: boolean): string {
  if (phase !== "tally") return "—";
  return tallyReady ? "READY" : "WAITING";
}

function phaseCaption(
  phase: RoundPhase,
  owes: boolean,
  rush: boolean,
  remaining: bigint,
  tallyReady: boolean
): string {
  if (rush) return "Under 90s — you still owe";
  if (owes) return "You still owe something";
  switch (phase) {
    case "campaign":
      return "Until the ballot opens";
    case "ballot":
      return "Calm — you owe nothing";
    case "tally":
      if (remaining > 0n) return tallyReady ? "Counts are in — anyone can settle this round" : "Until the round may be abandoned";
      // Two very different waits, and conflating them is what made a finished round look stuck.
      return tallyReady
        ? "Counts are in — anyone can settle this round"
        : "Waiting for the committee to publish the counts";
    default:
      return "Settled";
  }
}

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

/// Rounds advance on wall-clock time, not on transactions, so the countdown ticks locally rather
/// than waiting for an event that will never arrive.
function useNow(): bigint {
  const [now, setNow] = useState(() => BigInt(Math.floor(Date.now() / 1000)));

  useEffect(() => {
    const id = setInterval(() => setNow(BigInt(Math.floor(Date.now() / 1000))), 1000);
    return () => clearInterval(id);
  }, []);

  return now;
}
