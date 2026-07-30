import { useEffect, useState, type FC } from "react";
import type { VotingStep } from "../utils/types";
import { formatCountdown } from "../utils/tribes";

interface SealingProps {
  step: VotingStep;
  message: string;
  txHash?: string | null;
  /// A prefix of the encoded proof actually submitted. Absent until there is one — nothing is
  /// invented to fill the space.
  ciphertext?: string | null;
  onAbandon?: () => void;
}

/// The steps the wallet and the SDK actually take, in order. Named after what the machine is doing
/// rather than what it means, because a ledger of real work is the thing that makes a minute of
/// waiting bearable.
const STEPS: { key: VotingStep; label: string }[] = [
  { key: "signing", label: "Authorising with your wallet" },
  { key: "generating_proof", label: "Sealing your ballot on this device" },
  { key: "broadcasting", label: "Handing the sealed ballot to the network" },
  { key: "complete", label: "Sealed" },
];

/// Three passages, one every ~20 seconds. The rules players most need and would otherwise never
/// read, delivered in the one window where they have nothing else to do. This doubles as the
/// first-vote primer, so nobody gets a separate tutorial they would skip.
const PASSAGES = [
  "Nobody — including the people who run this game — can see how you voted. Only the totals are ever decrypted.",
  "Anyone may push a blank ballot into your slot. That is why you can never prove how you voted, and why nobody can make you.",
  "You can change your vote until the window closes, and the last one is the one that counts. A vote promised early is not a vote delivered.",
];

/// The hardest component in the game, and it must never be a spinner.
///
/// Three things have to be true at once: the player believes the machine is working, knows the tab
/// must stay open, and has something worth reading for a minute.
///
/// What is deliberately *not* here: a percentage, or a constraint counter. The proving SDK reports
/// no progress — it returns when it returns — so any number finer than "which step, how long so far,
/// and the honest expected range" would be invented. The bar below tracks elapsed time against that
/// range and says so; it is not a progress bar and does not pretend to be one. An invented
/// percentage that sticks at 94% costs more trust than no percentage ever earned.
export const Sealing: FC<SealingProps> = ({ step, message, txHash, ciphertext, onAbandon }) => {
  const running = step !== "idle" && step !== "complete" && step !== "error";
  const elapsed = useElapsed(running);
  const passage = PASSAGES[Math.min(PASSAGES.length - 1, Math.floor(elapsed / 20))];

  useSealingTabTitle(running, elapsed);

  // The expected window, not a prediction. Past 90s the bar pins and the copy stops promising.
  const fraction = Math.min(1, elapsed / 90);
  const activeIndex = STEPS.findIndex((s) => s.key === step);

  if (step === "complete") {
    return (
      <div className="un-receipt un-dotfield">
        <div>
          <div className="un-receipt-head">
            <span className="un-receipt-mark" aria-hidden="true">
              ✓
            </span>
            <span className="un-receipt-title">Sealed</span>
          </div>
          <p className="un-receipt-body">
            {message || "Submitted."} The counts open when the tally begins. Not even you can open it again.
          </p>
          {ciphertext && (
            <div className="un-cipher">
              <div className="un-cipher-label" style={{ color: "#b6d9bf" }}>
                Ciphertext — this is all anyone ever sees
              </div>
              <div className="un-cipher-bytes" style={{ color: "#d7ecdc" }}>
                {ciphertext} …
              </div>
            </div>
          )}
          {txHash && (
            <div className="un-receipt-chain">
              tx {txHash}
              <br />
              <a href={`#tx-${txHash}`} onClick={(e) => e.preventDefault()}>
                verify on chain →
              </a>
            </div>
          )}
        </div>
      </div>
    );
  }

  if (step === "error") {
    // Never "something went wrong". Say exactly what happened and whether anything was submitted.
    return (
      <div className="un-error" role="alert">
        <strong>Nothing was submitted.</strong> {message}
      </div>
    );
  }

  if (!running) return null;

  return (
    <div className="un-seal un-dotfield">
      <div>
        <div className="un-label" style={{ marginBottom: 16 }}>
          Sealing your ballot
        </div>

        <div className="un-seal-elapsed">{formatCountdown(elapsed)}</div>
        <div className="un-seal-bar">
          <div className="un-seal-fill" style={{ width: `${fraction * 100}%` }} />
          <div className="un-seal-sweep" />
        </div>
        <div className="un-mono" style={{ fontSize: 11 }}>
          ELAPSED, AGAINST ~45–90s EXPECTED{elapsed > 90 ? " · LONGER THAN USUAL, STILL WORKING" : ""}
        </div>

        <div className="un-seal-steps">
          {STEPS.map((s, i) => {
            const state = activeIndex < 0 ? "" : i < activeIndex ? "done" : i === activeIndex ? "now" : "";
            return (
              <div key={s.key} className={`un-seal-step ${state ? `un-seal-step-${state}` : ""}`}>
                <span className="un-seal-tick" aria-hidden="true" />
                <span>{s.label}</span>
              </div>
            );
          })}
        </div>

        <p className="un-seal-keep">
          Keep this tab open. The proof is built on your device — close it and the work is lost, and nothing is
          submitted.
        </p>

        <p className="un-prose" style={{ marginTop: 18, fontSize: 15 }} aria-live="polite">
          {passage}
        </p>

        {onAbandon && (
          <button
            type="button"
            className="un-btn un-btn-ghost un-btn-block"
            style={{ marginTop: 14 }}
            onClick={onAbandon}
          >
            Abandon — nothing is sent
          </button>
        )}
      </div>
    </div>
  );
};

/// Seconds since the run started. Resets whenever a new one begins.
function useElapsed(running: boolean): number {
  const [elapsed, setElapsed] = useState(0);

  useEffect(() => {
    if (!running) {
      setElapsed(0);
      return;
    }
    const started = Date.now();
    const id = setInterval(() => setElapsed(Math.floor((Date.now() - started) / 1000)), 1000);
    return () => clearInterval(id);
  }, [running]);

  return elapsed;
}

/// Backgrounded, the work continues — so the tab title carries the state, because the tab is often
/// the only thing the player can see of it.
function useSealingTabTitle(running: boolean, elapsed?: number) {
  useEffect(() => {
    if (!running) return;
    const original = document.title;
    document.title = elapsed ? `${elapsed}s · sealing · UNRAVEL` : "sealing · UNRAVEL";
    return () => {
      document.title = original;
    };
  }, [running, elapsed]);
}
