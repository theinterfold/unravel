import { useEffect, useState } from "react";
import { parseAbiItem, type Address } from "viem";
import { PUB_GAME_ADDRESS, PUB_DEPLOYMENT_BLOCK } from "@/constants";
import { publicClient } from "../utils/client";

export type TallyOutcome =
  | { kind: "eliminated"; counts: bigint[]; player: Address; team: number }
  | { kind: "council"; counts: bigint[]; team: number }
  | { kind: "void" }
  | { kind: "aborted" };

/// The decrypted counts for a settled round.
///
/// Read from settlement events rather than from the voting plugin, because the events are what the
/// game itself acted on — the counts in `PlayerEliminated` are the exact array `settleRound` used to
/// pick a victim. Reading the plugin separately would be a second source that could disagree.
///
/// Nothing here exists before settlement, and that is deliberate rather than a limitation: a turnout
/// figure does not exist before decryption, so there is nothing to show and no partial state to
/// render. Total ballots cast is stated after the reveal, never before.
// `team` is indexed in both, so it arrives in the topics rather than the data. Declaring it
// non-indexed still parses, but decodes the counts array from the wrong offset.
const ELIMINATED = parseAbiItem(
  "event PlayerEliminated(uint256 indexed round, address indexed player, uint8 indexed team, uint256[] counts)"
);
const COUNCIL = parseAbiItem("event TeamSentToCouncil(uint256 indexed round, uint8 indexed team, uint256[] counts)");
const VOID = parseAbiItem("event RoundVoid(uint256 indexed round, uint256 indexed e3Id)");
const ABORTED = parseAbiItem("event RoundAborted(uint256 indexed round, uint256 indexed e3Id)");

export function useTally(round: number | undefined, settled: boolean, pollMs = 15_000) {
  const [outcome, setOutcome] = useState<TallyOutcome | undefined>();
  const [isLoading, setIsLoading] = useState(false);

  useEffect(() => {
    setOutcome(undefined);
    if (round === undefined || !settled) return;

    let cancelled = false;

    const load = async () => {
      setIsLoading(true);
      try {
        const scope = {
          address: PUB_GAME_ADDRESS,
          args: { round: BigInt(round) },
          fromBlock: BigInt(PUB_DEPLOYMENT_BLOCK),
          toBlock: "latest" as const,
        };

        const [eliminated, council, voided, aborted] = await Promise.all([
          publicClient.getLogs({ ...scope, event: ELIMINATED }),
          publicClient.getLogs({ ...scope, event: COUNCIL }),
          publicClient.getLogs({ ...scope, event: VOID }),
          publicClient.getLogs({ ...scope, event: ABORTED }),
        ]);

        if (cancelled) return;

        // Order matters. A tribal round emits TeamSentToCouncil and, when the condemned tribe has
        // exactly one member left, PlayerEliminated in the same transaction — the elimination is
        // the more specific outcome and is what the player needs to see.
        const kill = eliminated.at(-1);
        if (kill) {
          setOutcome({
            kind: "eliminated",
            counts: [...((kill.args.counts as readonly bigint[]) ?? [])],
            player: kill.args.player as Address,
            team: Number(kill.args.team ?? 0),
          });
          return;
        }

        const sent = council.at(-1);
        if (sent) {
          setOutcome({
            kind: "council",
            counts: [...((sent.args.counts as readonly bigint[]) ?? [])],
            team: Number(sent.args.team ?? 0),
          });
          return;
        }

        if (aborted.length > 0) setOutcome({ kind: "aborted" });
        else if (voided.length > 0) setOutcome({ kind: "void" });
      } catch (e) {
        console.error("useTally:", e);
      } finally {
        if (!cancelled) setIsLoading(false);
      }
    };

    void load();
    const id = setInterval(load, pollMs);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [round, settled, pollMs]);

  return { outcome, isLoading };
}
