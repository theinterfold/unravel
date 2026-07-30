import { useEffect, useState } from "react";
import { useAccount, useWriteContract } from "wagmi";
import { PUB_GAME_ADDRESS } from "@/constants";

import { SurvivalGameAbi } from "../artifacts/SurvivalGame";
import { useGame, useRound, useCurrentRoundId, useTeams } from "../hooks/useGame";
import { useCheckIn } from "../hooks/useCheckIn";
import { useTally } from "../hooks/useTally";
import { useSealedLocally } from "../hooks/useSealedLocally";
import { Roster } from "../components/roster";
import { Ballot } from "../components/ballot";
import { Campaign } from "../components/campaign";
import { RoundStatus } from "../components/roundStatus";
import { Reveal } from "../components/reveal";
import { CheckIn, CheckInTakeover, shouldTakeOver } from "../components/checkIn";
import { RoundKind, Stage, ZERO_ADDRESS } from "../utils/gameTypes";
import { shortAddress, sameAddress, tribe } from "../utils/tribes";
import type { Address } from "viem";

export default function GamePage() {
  const { address } = useAccount();
  const { game, isLoading } = useGame();
  const roundId = useCurrentRoundId();
  const { round } = useRound(roundId);
  const { writeContractAsync, isPending } = useWriteContract();
  const [team, setTeam] = useState(1);
  const now = useNow();

  const allPlayers = [...(game?.alive ?? []), ...(game?.jurors ?? [])];
  const teamOf = useTeams(allPlayers);
  const checkIn = useCheckIn(address, roundId, game?.config.maxMissedCheckIns ?? 0);
  const { outcome } = useTally(roundId, round?.settled ?? false);
  const { sealed, markSealed } = useSealedLocally(round?.e3Id);

  if (isLoading || !game) {
    return (
      <main className="un">
        <div className="un-wrap" style={{ paddingTop: 80 }}>
          <p className="un-label">Reading the board…</p>
        </div>
      </main>
    );
  }

  const isAlive = !!address && game.alive.some((p) => sameAddress(p, address));
  const isJuror = !!address && game.jurors.some((p) => sameAddress(p, address));

  // Eligibility is the round's own voter list, which narrows in council rounds (one tribe) and jury
  // rounds (the dead) — not simply "everyone alive".
  const isVoter = !!round && !!address && round.voters.some((v) => sameAddress(v, address));
  const inCampaign = !!round && now < round.ballotOpensAt;
  const inBallot = !!round && now >= round.ballotOpensAt && now < round.ballotClosesAt;
  const canVote = isVoter && inBallot;
  const merged = !!round && (round.kind === RoundKind.Individual || round.kind === RoundKind.Jury);

  // What the player still owes, and therefore whether the clock is allowed to panic. Ballots are
  // secret, so "have I voted?" is only knowable from this browser — see useSealedLocally.
  const owesCheckIn = isAlive && !checkIn.current && !checkIn.immature;
  const owesBallot = canVote && !sealed;
  const owes = owesCheckIn || owesBallot;

  const secondsLeft = round && inBallot ? round.ballotClosesAt - now : 0n;
  const takeover = isAlive && shouldTakeOver(checkIn, secondsLeft);

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
    <main className="un">
      {takeover && <CheckInTakeover state={checkIn} secondsLeft={secondsLeft} />}

      <Masthead game={game} address={address} />

      <div className="un-wrap un-stack" style={{ gap: 18, paddingTop: 22 }}>
        {game.stage === Stage.Ended && game.winner !== ZERO_ADDRESS && (
          <section className="un-certificate">
            <div className="un-label" style={{ color: "var(--un-green)" }}>
              Settled · {game.roundCount} rounds
            </div>
            <h2 className="un-verdict" style={{ marginTop: 14 }}>
              {shortAddress(game.winner)} <em>wins</em>.
            </h2>
            <p className="un-mono" style={{ marginTop: 14, color: "#4c534c" }}>
              POT {game.pot.toString()} PAID OUT
            </p>
          </section>
        )}

        {game.stage === Stage.Lobby && (
          <section className="un-panel un-stack">
            <div className="un-label-dim">
              Lobby · {game.alive.length} of {lobbySize} seats taken
            </div>
            <h2 className="un-title">Pick a tribe</h2>
            <p className="un-note" style={{ maxWidth: "62ch" }}>
              {game.config.teamCount} tribes of {game.config.membersPerTeam}. The game starts when every seat is full,
              and anyone can start it — a full lobby is an objective fact, not a privilege.
            </p>
            <div className="un-row">
              <select
                className="un-select"
                value={team}
                onChange={(e) => setTeam(Number(e.target.value))}
                disabled={isAlive}
                aria-label="Tribe"
              >
                {Array.from({ length: game.config.teamCount }, (_, i) => i + 1).map((t) => (
                  <option key={t} value={t}>
                    {tribe(t)?.name ?? `TEAM ${t}`}
                  </option>
                ))}
              </select>
              <button type="button" className="un-btn" disabled={isPending || isAlive} onClick={() => void joinTeam()}>
                {isAlive ? "You're in" : "Take a seat"}
              </button>
              <button
                type="button"
                className="un-btn un-btn-ghost"
                disabled={isPending || game.alive.length !== lobbySize}
                onClick={() => void call("startGame")}
              >
                Start the game
              </button>
            </div>
          </section>
        )}

        {round && <RoundStatus round={round} tallyGrace={game.config.tallyGrace} owes={owes} />}

        {isAlive && round && !round.settled && !checkIn.immature && (
          <CheckIn state={checkIn} secondsLeft={secondsLeft} />
        )}

        {round?.settled && <Reveal round={round} outcome={outcome} self={address} />}

        {round && !round.settled && canVote && (
          <Ballot round={round} canVote={canVote} self={address} onSealed={markSealed} />
        )}

        {round && !round.settled && isVoter && !canVote && !inCampaign && (
          <section className="un-panel">
            <div className="un-label-dim">Ballot closed</div>
            <p className="un-note" style={{ marginTop: 8 }}>
              The window has closed and the committee is decrypting. Only the totals come back.
            </p>
          </section>
        )}

        {round && !round.settled && !isVoter && (
          <section className="un-panel">
            <div className="un-label-dim">You are watching</div>
            <p className="un-prose" style={{ marginTop: 8 }}>
              {round.kind === RoundKind.Council
                ? "Only the condemned tribe votes this round. You put them here; you do not get to choose which of them goes."
                : round.kind === RoundKind.Jury
                  ? "Only the eliminated vote in the jury round."
                  : "You are not in this round's electorate."}
            </p>
          </section>
        )}

        <Roster
          alive={game.alive}
          graveyard={game.jurors}
          teamOf={teamOf}
          self={address}
          condemnedTeam={round?.kind === RoundKind.Council ? round.targetTeam : undefined}
          merged={merged}
          openSeats={game.stage === Stage.Lobby ? Math.max(0, lobbySize - game.alive.length) : 0}
        />

        {round && roundId !== undefined && (
          <Campaign
            round={roundId}
            canPost={inCampaign && isVoter && (isAlive || isJuror)}
            self={address}
            closed={!inCampaign}
          />
        )}

        {/* Both are permissionless by design: the tally is public and the outcome is a pure function
            of it, so anyone can push the game forward and nobody can stall it. */}
        {round && (
          <div className="un-row">
            {!round.settled && (
              <button
                type="button"
                className="un-btn un-btn-ghost un-btn-sm"
                disabled={isPending}
                onClick={() => void call("settleRound")}
              >
                Settle the round
              </button>
            )}
            {round.settled && game.stage !== Stage.Ended && (
              <button
                type="button"
                className="un-btn un-btn-ghost un-btn-sm"
                disabled={isPending}
                onClick={() => void call("openRound")}
              >
                Open the next round
              </button>
            )}
            <span className="un-fine">Anyone can do this. It is a clock, not a privilege.</span>
          </div>
        )}
      </div>
    </main>
  );
}

/// Cream chrome — the only place the game goes light while you are alive.
const Masthead = ({
  game,
  address,
}: {
  game: { stage: Stage; alive: Address[]; pot: bigint; roundCount: number };
  address?: Address;
}) => (
  <header className="un-masthead">
    <h1 className="un-wordmark">UNRAVEL</h1>
    <div className="un-row" style={{ gap: 16 }}>
      <span className="un-mono" style={{ fontSize: 11, letterSpacing: ".18em", color: "#4c534c" }}>
        {stageLabel(game.stage)} · {game.alive.length} ALIVE · POT {game.pot.toString()}
      </span>
      {address && (
        <span className="un-tag un-tag-you" title={address}>
          {shortAddress(address)}
        </span>
      )}
    </div>
  </header>
);

function stageLabel(stage: Stage): string {
  switch (stage) {
    case Stage.Lobby:
      return "LOBBY";
    case Stage.Playing:
      return "IN PLAY";
    case Stage.Jury:
      return "JURY";
    case Stage.Ended:
      return "SETTLED";
  }
}

function useNow(): bigint {
  const [now, setNow] = useState(() => BigInt(Math.floor(Date.now() / 1000)));
  useEffect(() => {
    const id = setInterval(() => setNow(BigInt(Math.floor(Date.now() / 1000))), 1000);
    return () => clearInterval(id);
  }, []);
  return now;
}
