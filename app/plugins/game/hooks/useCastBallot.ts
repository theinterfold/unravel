import { PUB_CRISP_SERVER_URL } from "@/constants";
import { useState } from "react";
import { useAccount, useSignMessage } from "wagmi";
import { hashMessage } from "viem";
import { encodeSolidityProof } from "@crisp-e3/sdk";

import { useAlerts } from "@/context/Alerts";
import { crispSdk } from "../utils/crispSdk";
import { getRandomVoterToMask } from "../utils/voters";
import { CreditsMode } from "../utils/types";
import type { EligibleVoter, IRoundDetailsResponse, VotingStep } from "../utils/types";

interface CastBallotState {
  isLoading: boolean;
  error: string;
  /// Casts an encrypted ballot for the candidate at `candidateIndex` in the round's candidate list.
  castBallot: (candidateIndex: number, e3Id: bigint) => Promise<void>;
  /// Submits a zero-vote into another voter's slot. See `castMask` below for why this exists.
  castMask: (e3Id: bigint) => Promise<void>;
  votingStep: VotingStep;
  stepMessage: string;
  txHash: string | null;
  /// A short prefix of the encoded proof actually submitted, for display. See `setCiphertext`.
  ciphertext: string | null;
}

interface VoteResponse {
  status: string;
  tx_hash: string | null;
  message: string | null;
  is_vote_update: boolean | null;
}

/**
 * Casting an encrypted elimination ballot.
 *
 * Adapted from the governance app's `useCrispServer`, simplified for the game's ballot shape:
 * every voter has exactly one credit (`CreditMode.CONSTANT`, `credits = 1`), so there is no token
 * balance to look up and no scaling to mirror — the vote vector is a single 1 in the chosen
 * candidate's slot.
 *
 * Two CRISP behaviours are surfaced deliberately, because in this game they are mechanics rather
 * than implementation details:
 *
 * - **Re-voting.** Casting again overwrites the previous ballot; the last one before the window
 *   closes is what counts. A vote promised early is not a vote delivered.
 * - **Masking.** Anyone can push a zero-vote into anyone else's slot, which makes it impossible to
 *   prove which ciphertext was yours. That is what stops votes being sold, and it is why a player
 *   can genuinely promise one thing and do another.
 */
export function useCastBallot(): CastBallotState {
  const { address } = useAccount();
  const { addAlert } = useAlerts();
  const { signMessageAsync } = useSignMessage();

  const [votingStep, setVotingStep] = useState<VotingStep>("idle");
  const [stepMessage, setStepMessage] = useState<string>("");
  const [isLoading, setIsLoading] = useState<boolean>(false);
  const [error, setError] = useState<string>("");
  const [txHash, setTxHash] = useState<string | null>(null);
  const [ciphertext, setCiphertext] = useState<string | null>(null);

  const getRoundState = async (e3Id: bigint): Promise<IRoundDetailsResponse> =>
    (await crispSdk.getRoundStateLite(Number(e3Id))) as unknown as IRoundDetailsResponse;

  const getMerkleLeaves = async (e3Id: bigint): Promise<bigint[]> => {
    const hashes = await crispSdk.getTokenHolderHashes(Number(e3Id));
    return hashes.map((h) => BigInt(h.startsWith("0x") ? h : `0x${h}`));
  };

  const getEligibleVoters = async (e3Id: bigint): Promise<EligibleVoter[]> => {
    const holders = await crispSdk.getEligibleAddresses(Number(e3Id));
    return holders.map((v) => ({ address: v.address, balance: BigInt(v.balance) }));
  };

  /// Every voter is credited the same amount, so the "balance" in the proof is just the round's
  /// constant credit. A round that is not CONSTANT is a misconfigured game, not a case to handle.
  const creditsFor = (roundState: IRoundDetailsResponse): bigint => {
    if (roundState.credit_mode !== CreditsMode.CONSTANT || !roundState.credits) {
      throw new Error("Elimination ballots must use CreditMode.CONSTANT — check how the round was requested");
    }
    return BigInt(roundState.credits);
  };

  const submit = async (e3Id: bigint, isMask: boolean, candidateIndex: number) => {
    setIsLoading(true);
    setError("");

    try {
      if (!address) throw new Error("No wallet connected");

      const roundState = await getRoundState(e3Id);
      const publicKey = new Uint8Array(roundState.committee_public_key);

      if (publicKey.length === 0 || roundState.status !== "Active") {
        throw new Error("The committee key has not been published yet. Please wait and try again.");
      }

      const numOptions = Number.parseInt(roundState.num_options, 10);
      const credits = creditsFor(roundState);
      const merkleLeaves = await getMerkleLeaves(e3Id);

      let proof;

      if (isMask) {
        const eligible = await getEligibleVoters(e3Id);
        if (eligible.length === 0) throw new Error("No eligible voters available to mask");

        // The zero vote is constructed inside `generateMaskVoteProof` from `numOptions`; there is
        // nothing for the caller to build.
        const slot = getRandomVoterToMask(eligible);

        setVotingStep("generating_proof");
        setStepMessage("Generating mask...");

        proof = await crispSdk.generateMaskVoteProof({
          e3Id: Number(e3Id),
          merkleLeaves,
          slotAddress: slot.address,
          publicKey,
          balance: slot.balance,
          numOptions,
        });
      } else {
        if (candidateIndex < 0 || candidateIndex >= numOptions) {
          throw new Error(`Candidate index ${candidateIndex} is outside this round's ${numOptions} options`);
        }

        setVotingStep("signing");
        setStepMessage("Sign the message in your wallet to authorise your ballot...");

        const message = `Vote for round ${e3Id}`;
        const signature = await signMessageAsync({ message });
        const messageHash = hashMessage(message);

        // One credit, one candidate. The circuit enforces `total <= balance`, so this is the only
        // shape a valid one-credit ballot can take.
        const vote = Array.from({ length: numOptions }, (_, i) => (i === candidateIndex ? Number(credits) : 0));

        setVotingStep("generating_proof");
        setStepMessage("Encrypting your ballot and generating the proof...");

        proof = await crispSdk.generateVoteProof({
          merkleLeaves,
          publicKey,
          balance: credits,
          vote,
          signature: signature as `0x${string}`,
          messageHash: messageHash as `0x${string}`,
          e3Id: Number(e3Id),
          slotAddress: address,
        });
      }

      setVotingStep("broadcasting");
      setStepMessage("Broadcasting...");

      // What the world gets to see of your vote. Shown to the player as a prefix of the real encoded
      // proof rather than as generated hex: a decorative blob would be the same class of lie as an
      // invented progress percentage, and this component's whole argument is that the bytes are all
      // anyone ever has.
      const encoded = encodeSolidityProof(proof);
      setCiphertext(
        encoded
          .replace(/^0x/, "")
          .slice(0, 24)
          .replace(/(.{4})/g, "$1 ")
          .trim()
      );

      const response = await fetch(`${PUB_CRISP_SERVER_URL}/voting/broadcast`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          encoded_proof: encoded,
          address,
          round_id: Number(e3Id),
        }),
      });

      if (response.status !== 200) throw new Error("The CRISP server rejected the ballot");

      const result = (await response.json()) as VoteResponse;
      if (result.tx_hash) setTxHash(result.tx_hash);

      const label = isMask ? "Mask" : result.is_vote_update ? "Ballot update" : "Ballot";
      setVotingStep("complete");
      setStepMessage(`${label} submitted.`);
      addAlert(`${label} submitted.`, { timeout: 3000, type: "success" });
    } catch (e) {
      const message = e instanceof Error ? e.message : "Unknown error";
      console.error("castBallot:", e);
      setError(message);
      setVotingStep("error");
      setStepMessage(message);
    } finally {
      setIsLoading(false);
    }
  };

  return {
    castBallot: (candidateIndex: number, e3Id: bigint) => submit(e3Id, false, candidateIndex),
    castMask: (e3Id: bigint) => submit(e3Id, true, -1),
    error,
    isLoading,
    votingStep,
    stepMessage,
    txHash,
    ciphertext,
  };
}
