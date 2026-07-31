import { useEffect, useState } from "react";
import { parseAbiItem } from "viem";
import { PUB_INTERFOLD_ADDRESS, PUB_DEPLOYMENT_BLOCK } from "@/constants";
import { publicClient } from "../utils/client";

export type PublishedInput = {
  index: number;
  /// The commitment Interfold recorded for this ciphertext.
  inputHash: bigint;
  txHash: string;
  blockNumber: bigint;
};

/// Ciphertexts published for a round.
///
/// This is the one thing about a live ballot that is genuinely public: every sealed ballot is
/// relayed to Interfold by the coordination server, and `InputPublished` records a commitment to it.
/// Showing the stream is showing exactly what an observer of the chain already has.
///
/// What it is emphatically *not* is turnout. The count includes masks, which anyone may drop into
/// anyone's slot, and re-votes, which replace an earlier ballot without removing its ciphertext. Ten
/// entries could be ten voters, or one voter changing their mind ten times, or nine masks. Any UI
/// built on this must say so, or it silently becomes the turnout indicator the design forbids.
const INPUT_PUBLISHED = parseAbiItem(
  "event InputPublished(uint256 indexed e3Id, bytes data, uint256 inputHash, uint256 index)"
);

export function useInputs(e3Id: bigint | undefined, pollMs = 15_000) {
  const [inputs, setInputs] = useState<PublishedInput[]>([]);
  const [isLoading, setIsLoading] = useState(false);

  useEffect(() => {
    if (e3Id === undefined || !PUB_INTERFOLD_ADDRESS) return;
    let cancelled = false;

    const load = async () => {
      setIsLoading(true);
      try {
        const logs = await publicClient.getLogs({
          address: PUB_INTERFOLD_ADDRESS,
          event: INPUT_PUBLISHED,
          args: { e3Id },
          fromBlock: BigInt(PUB_DEPLOYMENT_BLOCK),
          toBlock: "latest",
        });
        if (cancelled) return;

        setInputs(
          logs.map((log) => ({
            index: Number(log.args.index ?? 0),
            inputHash: (log.args.inputHash as bigint | undefined) ?? 0n,
            txHash: log.transactionHash ?? "",
            blockNumber: log.blockNumber ?? 0n,
          }))
        );
      } catch (e) {
        console.error("useInputs:", e);
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
  }, [e3Id, pollMs]);

  return { inputs, isLoading };
}
