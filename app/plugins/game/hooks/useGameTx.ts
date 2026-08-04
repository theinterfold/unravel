import { useCallback, useState } from "react";
import { useWriteContract } from "wagmi";
import { useAlerts } from "@/context/Alerts";
import { publicClient } from "../utils/client";
import { describeGameError } from "../utils/errors";

/// Where a transaction is between the click and the chain agreeing.
///
/// `signing` is the wallet prompt; `mining` is everything after it. They are separate because they
/// fail differently and take wildly different amounts of time — a rejected signature is instant and
/// is not an error, while mining on Sepolia is ten seconds of nothing happening.
export type TxPhase = "idle" | "signing" | "mining";

export type GameTx = {
  /// Sends, waits for the receipt, and reports failure as a sentence. Resolves true on success.
  run: (label: string, write: () => Promise<`0x${string}`>) => Promise<boolean>;
  phase: TxPhase;
  /// True from click until the receipt lands. What buttons should disable on.
  isBusy: boolean;
};

/// One transaction lifecycle for the whole game plugin.
///
/// Every write here used to resolve on `writeContractAsync`, which returns when the transaction is
/// *sent*, not mined. So the UI declared success while the chain had not agreed yet: "Posted."
/// appeared over a feed that did not contain the post, "Refunded." over an unchanged balance, and
/// Settle re-enabled itself as though nothing had happened. Worse, a transaction that reverted
/// on-chain — as opposed to failing simulation — reported success, because the throw never came.
///
/// The plugin keeps its own lifecycle rather than using `useTransactionManager` for one reason:
/// `describeGameError`. A game revert is `TeamFull(1)` or `TallyNotPublished()`, and turning those
/// into something a player can act on is the entire point; the generic decoder cannot.
export function useGameTx(): GameTx {
  const { writeContractAsync } = useWriteContract();
  const { addAlert } = useAlerts();
  const [phase, setPhase] = useState<TxPhase>("idle");

  const run = useCallback(
    async (label: string, write: () => Promise<`0x${string}`>): Promise<boolean> => {
      try {
        setPhase("signing");
        const hash = await write();

        setPhase("mining");
        const receipt = await publicClient.waitForTransactionReceipt({ hash });

        // A reverted transaction still produces a receipt, and `writeContractAsync` will not have
        // thrown for it — simulation passed, execution did not. Without this the failure is silent.
        if (receipt.status !== "success") {
          console.error(`${label}: reverted`, hash);
          addAlert("The transaction failed on chain.", {
            type: "error",
            description: "It was accepted by the network but reverted when it ran.",
            txHash: hash,
          });
          return false;
        }

        return true;
      } catch (e) {
        console.error(`${label}:`, e);
        addAlert(describeGameError(e), { type: "error" });
        return false;
      } finally {
        setPhase("idle");
      }
    },
    [addAlert]
  );

  return { run, phase, isBusy: phase !== "idle" };
}

/// Button text for a transaction in flight, so every button says the same thing.
export function txLabel(phase: TxPhase, idle: string): string {
  if (phase === "signing") return "Confirm in your wallet…";
  if (phase === "mining") return "Waiting for the chain…";
  return idle;
}

export { useGameTx as default };
