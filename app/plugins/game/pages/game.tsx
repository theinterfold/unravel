import { useAccount, useWriteContract } from "wagmi";
import { Button } from "@aragon/ods";
import { PUB_GAME_ADDRESS } from "@/constants";
import { AddressText } from "@/components/text/address";
import { PleaseWaitSpinner } from "@/components/please-wait";
import { MainSection } from "@/components/layout/main-section";

import { SurvivalGameAbi } from "../artifacts/SurvivalGame";
import { useGame, useRound, useCurrentRoundId } from "../hooks/useGame";
import { Roster } from "../components/roster";
import { Ballot } from "../components/ballot";
import { Campaign } from "../components/campaign";
import { RoundStatus } from "../components/roundStatus";
import { Stage, ZERO_ADDRESS } from "../utils/gameTypes";
import type { Address } from "viem";

export default function GamePage() {
  const { address } = useAccount();
  const { game, isLoading } = useGame();
  const roundId = useCurrentRoundId();
  const { round } = useRound(roundId);
  const { writeContractAsync, isPending } = useWriteContract();

  if (isLoading || !game) {
    return (
      <MainSection>
        <PleaseWaitSpinner />
      </MainSection>
    );
  }

  const isAlive = !!address && game.alive.some((p) => eq(p, address));
  const isJuror = !!address && game.jurors.some((p) => eq(p, address));
  const now = BigInt(Math.floor(Date.now() / 1000));

  // Voting eligibility is the round's own voter list — which is the graveyard, not the survivors,
  // once the jury round starts.
  const canVote =
    !!round &&
    !!address &&
    round.voters.some((v) => eq(v, address)) &&
    now >= round.ballotOpensAt &&
    now < round.ballotClosesAt;

  const inCampaign = !!round && now < round.ballotOpensAt;

  const call = (functionName: "join" | "startGame" | "openRound" | "settleRound") =>
    writeContractAsync({ address: PUB_GAME_ADDRESS, abi: SurvivalGameAbi, functionName, args: [] });

  return (
    <MainSection>
      <div className="flex w-full flex-col gap-6">
        <Header stage={game.stage} winner={game.winner} aliveCount={game.alive.length} pot={game.pot} />

        {game.stage === Stage.Lobby && (
          <div className="box-border flex flex-col gap-3 rounded-xl border border-neutral-100 bg-neutral-0 p-4 xl:p-6">
            <p className="text-sm text-neutral-600">
              {game.alive.length} of {game.config.rosterSize} players have joined.
            </p>
            <div className="flex gap-2">
              <Button size="md" disabled={isPending || isAlive} onClick={() => call("join")}>
                {isAlive ? "You're in" : "Join"}
              </Button>
              <Button
                size="md"
                variant="tertiary"
                disabled={isPending || game.alive.length !== game.config.rosterSize}
                onClick={() => call("startGame")}
              >
                Start the game
              </Button>
            </div>
          </div>
        )}

        {round && <RoundStatus round={round} tallyGrace={game.config.tallyGrace} />}

        <Roster alive={game.alive} graveyard={game.jurors} self={address} />

        {round && !round.settled && canVote && (
          <Ballot e3Id={round.e3Id} candidates={round.candidates} canVote={canVote} self={address} />
        )}

        {round && roundId !== undefined && (
          <Campaign round={roundId} canPost={inCampaign && (isAlive || isJuror)} self={address} />
        )}

        {round && !round.settled && (
          <div className="flex gap-2">
            <Button size="md" variant="tertiary" disabled={isPending} onClick={() => call("settleRound")}>
              Settle round
            </Button>
          </div>
        )}

        {round?.settled && game.stage !== Stage.Ended && (
          <div className="flex gap-2">
            <Button size="md" disabled={isPending} onClick={() => call("openRound")}>
              Open the next round
            </Button>
          </div>
        )}
      </div>
    </MainSection>
  );
}

const Header = ({
  stage,
  winner,
  aliveCount,
  pot,
}: {
  stage: Stage;
  winner: Address;
  aliveCount: number;
  pot: bigint;
}) => (
  <div className="flex flex-col gap-1">
    <h1 className="text-3xl font-semibold text-neutral-800">UNRAVEL</h1>
    {stage === Stage.Lobby && <p className="text-neutral-500">Waiting for players.</p>}
    {stage === Stage.Playing && <p className="text-neutral-500">{aliveCount} left. One goes home each round.</p>}
    {stage === Stage.Jury && (
      <p className="text-neutral-500">Final two. The jury — everyone already voted out — picks the winner.</p>
    )}
    {stage === Stage.Ended && winner !== ZERO_ADDRESS && (
      <p className="text-neutral-500">
        Winner: <AddressText>{winner}</AddressText>
      </p>
    )}
    <p className="text-sm text-neutral-400">Pot: {pot.toString()}</p>
  </div>
);

function eq(a: Address, b: Address) {
  return a.toLowerCase() === b.toLowerCase();
}
