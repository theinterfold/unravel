import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from "viem";
import { MAX_TEAM_SIZE, Stage } from "./gameTypes";
import { tribe } from "./tribes";

/// Turns a contract revert into something a player can act on.
///
/// The raw viem error is four paragraphs of ABI plumbing ending in `TeamFull(uint8 team) (1)`, which
/// tells a player nothing about what to do next. Every custom error the game can throw at a player
/// is mapped here to a sentence that names the fix.
///
/// Errors are matched by name rather than by selector so this survives the ABI being regenerated.
/// Anything unmapped falls through to the revert's own short message — never to "something went
/// wrong", which is the one thing that is always true and never useful.
export function describeGameError(error: unknown): string {
  if (error instanceof BaseError) {
    // The wallet's own rejection is not a failure and should not be dressed as one.
    const rejected = error.walk((e) => e instanceof UserRejectedRequestError);
    if (rejected) return "You dismissed the wallet prompt. Nothing was sent.";

    const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) {
      const name = reverted.data?.errorName;
      const args = (reverted.data?.args ?? []) as readonly unknown[];
      const mapped = name ? describe(name, args) : undefined;
      if (mapped) return mapped;
      if (reverted.reason) return reverted.reason;
      if (name) return `The contract rejected this: ${name}.`;
    }

    return error.shortMessage || error.message;
  }

  return error instanceof Error ? error.message : "Unknown error";
}

function describe(name: string, args: readonly unknown[]): string | undefined {
  const n = (i: number) => Number(args[i] ?? 0);

  switch (name) {
    // ─── Lobby ───────────────────────────────────────────────────────────────────────────────
    case "TeamFull": {
      const t = tribe(n(0));
      return `${t?.name ?? `Team ${n(0)}`} is full — ${n(1) || MAX_TEAM_SIZE} is the most a tribe can hold, because a council ballot needs one option per member. Pick another tribe.`;
    }
    case "AlreadyJoined":
      return "You are already in this game.";
    case "InvalidTeam":
      return `There is no tribe ${n(0)}.`;
    case "TeamBelowMinimum": {
      const t = tribe(n(0));
      return `${t?.name ?? `Team ${n(0)}`} has ${n(1)} of the ${n(2)} players it needs. The game cannot start until every tribe meets its minimum.`;
    }
    case "LobbyIncomplete":
      return `${n(0)} of ${n(1)} players have joined. ${n(1) - n(0)} more before anyone can start.`;

    // ─── Rounds ──────────────────────────────────────────────────────────────────────────────
    case "WrongStage":
      return `That is not possible right now — the game is ${stageName(n(1))}.`;
    case "PreviousRoundUnsettled":
      return "The previous round has not settled yet.";
    case "RoundAlreadySettled":
      return "This round has already settled.";
    case "TallyNotDue":
      return "The round cannot be abandoned yet — the committee still has time to publish.";
    case "BallotStillOpen":
      return "The ballot is still open. A round cannot be settled while people can still vote.";
    case "TallyNotPublished":
      return "The committee has not published the counts yet. The round settles as soon as it does.";
    case "TallyLengthMismatch":
      return `The tally came back with ${n(1)} counts but this round has ${n(0)} options — the round cannot be settled from it.`;
    case "NotAVoter":
      return "You are not in this round's electorate.";
    case "NotAlive":
      return "Only players still in the game can do that.";
    case "NotInCampaign":
      return "The campaign window has closed for this round.";

    case "NoRounds":
      return "The game has not started yet.";
    case "TooFewOptions":
      return `A ballot needs at least two options and this round would have ${n(0)}.`;
    case "TooManyOptions":
      return `This round would need ${n(0)} ballot options, above the circuit's limit of ${MAX_TEAM_SIZE}.`;

    // ─── Money ───────────────────────────────────────────────────────────────────────────────
    case "InsufficientPot":
      // The contract passes (1, 0) as a sentinel for "empty", which would otherwise render as the
      // nonsense "1 needed, 0 available".
      return n(1) === 0
        ? "The pot is empty, so the round's E3 fee cannot be paid. Fund the game before opening another round."
        : `The pot cannot cover the round's fee — ${n(0)} needed, ${n(1)} available.`;
    case "NothingToWithdraw":
      return "There is nothing to withdraw.";

    // ─── Configuration, which a player can do nothing about ──────────────────────────────────
    case "InvalidConfig":
      return "This game was deployed with an impossible round shape and cannot be played.";
    case "ZeroAddress":
      return "This game was deployed with a missing contract address and cannot be played.";

    default:
      return undefined;
  }
}

function stageName(stage: number): string {
  switch (stage) {
    case Stage.Lobby:
      return "still in the lobby";
    case Stage.Playing:
      return "in play";
    case Stage.Jury:
      return "at the jury stage";
    case Stage.Ended:
      return "over";
    default:
      return "in another stage";
  }
}
