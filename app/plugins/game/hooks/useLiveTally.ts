import { useReadContract } from "wagmi";
import { PUB_CRISP_VOTING_PLUGIN_ADDRESS } from "@/constants";

/// The plugin's decoded tally, readable the moment the plaintext is published.
///
/// The game's own reveal reads settlement events, which only exist once someone has called
/// `settleRound`. Between the committee publishing and that call, the counts are decrypted, on
/// chain and public — but the app showed nothing, so a round that had plainly finished looked stuck.
///
/// This is a read of the same numbers `settleRound` will act on, so the reveal and the settlement
/// cannot disagree: whatever is shown here is what the contract will use.
const TALLY_ABI = [
  {
    type: "function",
    name: "getTally",
    stateMutability: "view",
    inputs: [{ name: "proposalId", type: "uint256" }],
    outputs: [{ name: "", type: "tuple", components: [{ name: "counts", type: "uint256[]" }] }],
  },
] as const;

export function useLiveTally(proposalId: bigint | undefined, enabled: boolean, pollMs = 15_000) {
  const { data } = useReadContract({
    address: PUB_CRISP_VOTING_PLUGIN_ADDRESS,
    abi: TALLY_ABI,
    functionName: "getTally",
    args: proposalId === undefined ? undefined : [proposalId],
    query: {
      enabled: enabled && proposalId !== undefined && !!PUB_CRISP_VOTING_PLUGIN_ADDRESS,
      refetchInterval: pollMs,
      // A tally that has not been published yet reverts or returns nothing; that is an expected
      // state for most of a round, not an error worth retrying hard.
      retry: false,
    },
  });

  const counts = (data as { counts?: readonly bigint[] } | undefined)?.counts;
  // An unpublished tally reads as an empty array. Distinguishing "no counts yet" from "all zero" is
  // what stops the UI announcing a void round before the committee has spoken.
  return counts && counts.length > 0 ? [...counts] : undefined;
}
