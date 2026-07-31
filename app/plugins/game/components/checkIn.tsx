import type { FC } from "react";
import { formatCountdown } from "../utils/tribes";
import { useAlerts } from "@/context/Alerts";
import type { CheckInState } from "../hooks/useCheckIn";
import { describeGameError } from "../utils/errors";

interface CheckInProps {
  state: CheckInState;
  /// Seconds until the current round's ballot closes, after which a miss is locked in.
  secondsLeft: bigint;
}

/// Liveness, and how close you are to dying of admin.
///
/// Check-in is deliberately the cheapest action in the game: one tap, no proof, no waiting.
/// Everything expensive happens on the ballot. Dying of admin should require real commitment.
///
/// It exists at all because forfeits cannot key off abstention — ballots are secret and mask votes
/// make slot activity meaningless, so the chain genuinely cannot tell who voted. This is the public
/// signal instead, and it leaks nothing about the ballot.
export const CheckIn: FC<CheckInProps> = ({ state, secondsLeft }) => {
  const { missed, limit, current, immature, isPending } = state;
  const checkIn = useGuardedCheckIn(state);

  if (current) {
    return (
      <div className="un-checkin">
        <Pips missed={0} limit={limit} tone="ok" />
        <span className="un-checkin-text">CHECKED IN · ALL CLEAR</span>
      </div>
    );
  }

  // Early rounds cannot forfeit anyone — the contract skips the sweep while `roundId <= limit`.
  // Alarming a player who is in no danger is how an alarm gets ignored when it matters.
  const final = !immature && missed >= limit - 1;

  if (!final) {
    return (
      <div className={`un-checkin ${missed > 0 ? "un-checkin-warn" : ""}`}>
        <Pips missed={missed} limit={limit} tone={missed > 0 ? "warn" : "ok"} />
        <span className="un-checkin-text">
          {missed > 0 ? `${missed} MISSED · CHECK IN NOW` : "NOT CHECKED IN THIS ROUND"}
        </span>
        <button
          type="button"
          className="un-btn un-btn-ghost un-btn-sm"
          style={{ marginLeft: "auto" }}
          disabled={isPending}
          onClick={() => void checkIn()}
        >
          {isPending ? "Signing…" : "Check in"}
        </button>
      </div>
    );
  }

  return (
    <div className="un-checkin un-checkin-final">
      <div className="un-row" style={{ marginBottom: 13, flexWrap: "nowrap" }}>
        <Pips missed={missed} limit={limit} tone="bad" />
        <span className="un-checkin-text">{missed} MISSED · ONE MORE ENDS YOU</span>
      </div>
      <button
        type="button"
        className="un-btn un-btn-danger un-btn-block"
        disabled={isPending}
        onClick={() => void checkIn()}
      >
        {isPending ? "Signing…" : "Check in — 1 tap, no proof"}
      </button>
      {secondsLeft > 0n && (
        <p className="un-fine" style={{ marginTop: 10, color: "var(--un-condemned-soft)" }}>
          {formatCountdown(secondsLeft)} until this round closes and the miss is locked in.
        </p>
      )}
    </div>
  );
};

/// The last-chance takeover: two misses and under two minutes on the clock.
///
/// The only takeover in the whole product, which is exactly why it works. Undismissable on purpose —
/// there is precisely one thing worth doing and dismissing it is not it.
export const CheckInTakeover: FC<CheckInProps> = ({ state, secondsLeft }) => {
  const checkIn = useGuardedCheckIn(state);
  return (
  <div className="un-takeover" role="alertdialog" aria-modal="true" aria-label="Check in now">
    <div className="un-label" style={{ color: "#fff" }}>
      {state.missed} missed · you are one round from elimination
    </div>
    <p className="un-takeover-line">Sign this or the game ends for you in {formatCountdown(secondsLeft)}.</p>
    <button type="button" className="un-btn" disabled={state.isPending} onClick={checkIn}>
      {state.isPending ? "Signing…" : "Check in"}
    </button>
    <p className="un-fine" style={{ color: "rgba(255,255,255,.8)" }}>
      One tap. No proof, no waiting, and it says nothing about how you voted.
    </p>
    </div>
  );
};

/// Check-in is the action most likely to be tapped under time pressure, so a silent failure here is
/// the worst one in the game — the player believes they are safe and is eliminated next round.
function useGuardedCheckIn(state: CheckInProps["state"]) {
  const { addAlert } = useAlerts();
  return () => {
    void state.checkIn().catch((e: unknown) => {
      console.error("checkIn:", e);
      addAlert(describeGameError(e), { type: "error" });
    });
  };
}

/// Whether the takeover should be showing. Kept next to the component so the threshold lives in one
/// place — it is the single most disruptive thing the UI can do.
export function shouldTakeOver(state: CheckInState, secondsLeft: bigint): boolean {
  return (
    !state.current && !state.immature && state.missed >= state.limit - 1 && secondsLeft > 0n && secondsLeft <= 120n
  );
}

const Pips: FC<{ missed: number; limit: number; tone: "ok" | "warn" | "bad" }> = ({ missed, limit, tone }) => {
  const slots = Math.max(1, limit);
  return (
    <span className="un-pips" aria-label={`${missed} of ${slots} missed`}>
      {Array.from({ length: slots }, (_, i) => {
        const spent = i < missed;
        const next = i === missed;
        const fill = spent ? (tone === "bad" ? "un-pip-bad" : tone === "warn" ? "un-pip-warn" : "un-pip-ok") : "";
        return <span key={i} className={`un-pip ${fill} ${next && tone === "bad" ? "un-pip-next" : ""}`} />;
      })}
    </span>
  );
};
