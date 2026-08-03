import { useEffect, useState } from "react";
import { parseAbiItem, type Address } from "viem";
import { PUB_DEPLOYMENT_BLOCK } from "@/constants";
import { publicClient } from "../utils/client";
import { useGameAddress } from "../utils/activeGame";

export type HistoryEntry =
  | { round: number; kind: "eliminated"; player: Address; team: number; counts: bigint[] }
  | { round: number; kind: "council"; team: number; counts: bigint[] }
  | { round: number; kind: "forfeited"; player: Address }
  | { round: number; kind: "void" }
  | { round: number; kind: "aborted" }
  | { round: number; kind: "merged"; survivors: number }
  | { round: number; kind: "won"; player: Address; prize: bigint };

/// Everything that has happened, oldest first.
///
/// The app only ever rendered the current round, so the reveal — the bars, the verdict, the whole
/// point of a round — vanished the instant somebody opened the next one. A game whose drama is
/// cumulative had no memory of it, and anyone arriving mid-game had no way to find out what they
/// had missed.
///
/// Built from settlement events rather than by reading each round back, because the events are what
/// the game actually did and they carry the counts. One query per event type, then merged.
const EVENTS = {
  eliminated: parseAbiItem(
    "event PlayerEliminated(uint256 indexed round, address indexed player, uint8 indexed team, uint256[] counts)"
  ),
  council: parseAbiItem("event TeamSentToCouncil(uint256 indexed round, uint8 indexed team, uint256[] counts)"),
  forfeited: parseAbiItem("event PlayerForfeited(uint256 indexed round, address indexed player)"),
  void: parseAbiItem("event RoundVoid(uint256 indexed round, uint256 indexed e3Id)"),
  aborted: parseAbiItem("event RoundAborted(uint256 indexed round, uint256 indexed e3Id)"),
  merged: parseAbiItem("event Merged(uint256 survivors)"),
  won: parseAbiItem("event WinnerDeclared(address indexed player, uint256 prize)"),
} as const;

export function useHistory(roundCount: number, pollMs = 20_000) {
  const gameAddress = useGameAddress();
  const [entries, setEntries] = useState<HistoryEntry[]>([]);

  useEffect(() => {
    if (!gameAddress) return;
    let cancelled = false;

    const load = async () => {
      try {
        const scope = {
          address: gameAddress,
          fromBlock: BigInt(PUB_DEPLOYMENT_BLOCK),
          toBlock: "latest" as const,
        };

        const [eliminated, council, forfeited, voided, aborted, merged, won] = await Promise.all([
          publicClient.getLogs({ ...scope, event: EVENTS.eliminated }),
          publicClient.getLogs({ ...scope, event: EVENTS.council }),
          publicClient.getLogs({ ...scope, event: EVENTS.forfeited }),
          publicClient.getLogs({ ...scope, event: EVENTS.void }),
          publicClient.getLogs({ ...scope, event: EVENTS.aborted }),
          publicClient.getLogs({ ...scope, event: EVENTS.merged }),
          publicClient.getLogs({ ...scope, event: EVENTS.won }),
        ]);
        if (cancelled) return;

        const out: HistoryEntry[] = [];
        for (const l of council) {
          out.push({
            round: Number(l.args.round),
            kind: "council",
            team: Number(l.args.team ?? 0),
            counts: [...((l.args.counts as readonly bigint[]) ?? [])],
          });
        }
        for (const l of eliminated) {
          out.push({
            round: Number(l.args.round),
            kind: "eliminated",
            player: l.args.player as Address,
            team: Number(l.args.team ?? 0),
            counts: [...((l.args.counts as readonly bigint[]) ?? [])],
          });
        }
        for (const l of forfeited) {
          out.push({ round: Number(l.args.round), kind: "forfeited", player: l.args.player as Address });
        }
        for (const l of voided) out.push({ round: Number(l.args.round), kind: "void" });
        for (const l of aborted) out.push({ round: Number(l.args.round), kind: "aborted" });
        // `Merged` and `WinnerDeclared` carry no round, so they are pinned to the latest one — they
        // only ever happen once, at a point the rest of the timeline already makes obvious.
        for (const l of merged) {
          out.push({ round: roundCount, kind: "merged", survivors: Number(l.args.survivors ?? 0) });
        }
        for (const l of won) {
          out.push({
            round: roundCount,
            kind: "won",
            player: l.args.player as Address,
            prize: (l.args.prize as bigint | undefined) ?? 0n,
          });
        }

        out.sort((a, b) => a.round - b.round);
        setEntries(out);
      } catch (e) {
        console.error("useHistory:", e);
      }
    };

    void load();
    const id = setInterval(load, pollMs);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [gameAddress, roundCount, pollMs]);

  return entries;
}
