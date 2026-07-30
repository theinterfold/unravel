import { useState } from "react";
import { useAccount, useWriteContract } from "wagmi";
import { Button } from "@aragon/ods";
import { PUB_GAME_ADDRESS } from "@/constants";
import { AddressText } from "@/components/text/address";
import { PleaseWaitSpinner } from "@/components/please-wait";
import { MainSection } from "@/components/layout/main-section";

import { SurvivalGameAbi } from "../artifacts/SurvivalGame";
import { useGame, useRound, useCurrentRoundId, useTeams } from "../hooks/useGame";
import { Roster } from "../components/roster";
import { Ballot } from "../components/ballot";
import { Campaign } from "../components/campaign";
import { RoundStatus } from "../components/roundStatus";
import { RoundKind, Stage, ZERO_ADDRESS } from "../utils/gameTypes";
import type { Address } from "viem";

export default function GamePage() {
  const { address } = useAccount();
  const { game, isLoading } = useGame();
  const roundId = useCurrentRoundId();
  const { round } = useRound(roundId);
  const { writeContractAsync, isPending } = useWriteContract();
  const [team, setTeam] = useState(1);

  const allPlayers = [...(game?.alive ?? []), ...(game?.jurors ?? [])];
  const teamOf = useTeams(allPlayers);

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

  // Eligibility is the round's own voter list, which narrows in council rounds (one team) and jury
  // rounds (the dead) — not simply "everyone alive".
  const isVoter = !!round && !!address && round.voters.some((v) => eq(v, address));
  const canVote = isVoter && now >= round!.ballotOpensAt && now < round!.ballotClosesAt;
  const inCampaign = !!round && now < round.ballotOpensAt;
  const merged = !!round && (round.kind === RoundKind.Individual || round.kind === RoundKind.Jury);

  const call = (functionName: "startGame" | "openRound" | "settleRound") =>
    writeContractAsync({ address: PUB_GAME_ADDRESS, abi: SurvivalGameAbi, functionName, args: [] });

  const joinTeam = () =>
    writeContractAsync({
      address: PUB_GAME_ADDRESS,
      abi: SurvivalGameAbi,
      functionName: "join",
      args: [team],
    });

  const lobbySize = game.config.teamCount * game.config.membersPerTeam;

  return (
    <MainSection>
      <div className="flex w-full flex-col gap-6">
        <Header stage={game.stage} winner={game.winner} aliveCount={game.alive.length} pot={game.pot} />

        {game.stage === Stage.Lobby && (
          <div className="box-border flex flex-col gap-3 rounded-xl border border-neutral-100 bg-neutral-0 p-4 xl:p-6">
            <p className="text-sm text-neutral-600">
              {game.alive.length} of {lobbySize} players joined — {game.config.teamCount} teams of{" "}
              {game.config.membersPerTeam}.
            </p>
            <div className="flex flex-wrap items-center gap-2">
              <select
                value={team}
                onChange={(e) => setTeam(Number(e.target.value))}
                disabled={isAlive}
                className="rounded-lg border border-neutral-100 bg-neutral-50 px-3 py-2 text-sm"
              >
                {Array.from({ length: game.config.teamCount }, (_, i) => i + 1).map((t) => (
                  <option key={t} value={t}>
                    Team {t}
                  </option>
                ))}
              </select>
              <Button size="md" disabled={isPending || isAlive} onClick={joinTeam}>
                {isAlive ? "You're in" : "Join"}
              </Button>
              <Button
                size="md"
                variant="tertiary"
                disabled={isPending || game.alive.length !== lobbySize}
                onClick={() => call("startGame")}
              >
                Start the game
              </Button>
            </div>
          </div>
        )}

        {round && <RoundStatus round={round} tallyGrace={game.config.tallyGrace} />}

        <Roster
          alive={game.alive}
          graveyard={game.jurors}
          teamOf={teamOf}
          self={address}
          condemnedTeam={round?.kind === RoundKind.Council ? round.targetTeam : undefined}
          merged={merged}
        />

        {round && !round.settled && canVote && <Ballot round={round} canVote={canVote} self={address} />}

        {round && !round.settled && isVoter && !canVote && !inCampaign && (
          <p className="text-sm text-neutral-500">The ballot has closed. Waiting for the tally.</p>
        )}

        {round && !round.settled && !isVoter && (
          <p className="text-sm text-neutral-500">
            {round.kind === RoundKind.Council
              ? "Only the condemned team votes this round. You are watching."
              : round.kind === RoundKind.Jury
                ? "Only the eliminated vote in the jury round."
                : "You are not in this round's electorate."}
          </p>
        )}

        {round && roundId !== undefined && (
          <Campaign round={roundId} canPost={inCampaign && isVoter && (isAlive || isJuror)} self={address} />
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
    {stage === Stage.Lobby && <p className="text-neutral-500">Waiting for players. Pick a team.</p>}
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
