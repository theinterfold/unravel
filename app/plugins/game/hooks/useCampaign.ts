import { useEffect, useState } from "react";
import { useWriteContract } from "wagmi";
import { parseAbiItem, type Address } from "viem";
import { PUB_GAME_ADDRESS, PUB_DEPLOYMENT_BLOCK } from "@/constants";
import { SurvivalGameAbi } from "../artifacts/SurvivalGame";
import { publicClient } from "../utils/client";

export type CampaignPost = {
  round: number;
  player: Address;
  cid: string;
  blockNumber: bigint;
};

const POSTED_EVENT = parseAbiItem("event Posted(uint256 indexed round, address indexed player, string cid)");

/// Reads the public campaign feed for a round.
///
/// Posts are events carrying an IPFS CID — the chain stores the pointer and the attribution, which
/// is the part that matters. What a player said, and that they are on record as having said it, is
/// the counterweight to a ballot nobody can trace.
export function useCampaignFeed(round: number | undefined, pollMs = 15_000) {
  const [posts, setPosts] = useState<CampaignPost[]>([]);
  const [isLoading, setIsLoading] = useState(false);

  useEffect(() => {
    if (round === undefined) return;
    let cancelled = false;

    const load = async () => {
      setIsLoading(true);
      try {
        const logs = await publicClient.getLogs({
          address: PUB_GAME_ADDRESS,
          event: POSTED_EVENT,
          args: { round: BigInt(round) },
          fromBlock: BigInt(PUB_DEPLOYMENT_BLOCK),
          toBlock: "latest",
        });

        if (cancelled) return;

        setPosts(
          logs.map((log) => ({
            round: Number(log.args.round),
            player: log.args.player as Address,
            cid: log.args.cid as string,
            blockNumber: log.blockNumber ?? 0n,
          }))
        );
      } catch (e) {
        console.error("useCampaignFeed:", e);
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
  }, [round, pollMs]);

  return { posts, isLoading };
}

/// Publishing a campaign post, and the public liveness check-in.
export function useCampaignActions() {
  const { writeContractAsync, isPending } = useWriteContract();

  const post = (cid: string) =>
    writeContractAsync({
      address: PUB_GAME_ADDRESS,
      abi: SurvivalGameAbi,
      functionName: "post",
      args: [cid],
    });

  // Liveness has to be an explicit signal: ballots are secret and masks make slot activity
  // meaningless, so nobody — including the contract — can tell who actually voted.
  const checkIn = () =>
    writeContractAsync({
      address: PUB_GAME_ADDRESS,
      abi: SurvivalGameAbi,
      functionName: "checkIn",
      args: [],
    });

  return { post, checkIn, isPending };
}
