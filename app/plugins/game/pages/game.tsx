import { useEffect, useState } from "react";
import { useAccount, useWriteContract } from "wagmi";
import { PUB_GAME_ADDRESS, PUB_CHAIN_NAME } from "@/constants";

import { SurvivalGameAbi } from "../artifacts/SurvivalGame";
import { useGame, useRound, useCurrentRoundId, useTeams } from "../hooks/useGame";
import { useCheckIn } from "../hooks/useCheckIn";
import { useTally, usePrize } from "../hooks/useTally";
import { useLiveTally } from "../hooks/useLiveTally";
import { useSealedLocally } from "../hooks/useSealedLocally";
import { useFeeToken } from "../hooks/useFeeToken";
import { Roster } from "../components/roster";
import { Ballot } from "../components/ballot";
import { Campaign } from "../components/campaign";
import { RoundStatus } from "../components/roundStatus";
import { Reveal } from "../components/reveal";
import { CheckIn, CheckInTakeover, shouldTakeOver } from "../components/checkIn";
import { Ciphertexts } from "../components/ciphertexts";
import { Finalists } from "../components/finalists";
import { MAX_TEAM_SIZE, RoundKind, Stage, ZERO_ADDRESS } from "../utils/gameTypes";
import { shortAddress, sameAddress, tribe } from "../utils/tribes";
import { describeGameError } from "../utils/errors";
import { useAlerts } from "@/context/Alerts";
import type { Address } from "viem";

export default function GamePage() {
  const { address } = useAccount();
  const { game, isLoading, error } = useGame();
  const roundId = useCurrentRoundId();
  const { round } = useRound(roundId);
  const { writeContractAsync, isPending } = useWriteContract();
  const { addAlert } = useAlerts();
  const [team, setTeam] = useState(1);
  const now = useNow();

  const allPlayers = [...(game?.alive ?? []), ...(game?.jurors ?? [])];
  const teamOf = useTeams(allPlayers);
  const checkIn = useCheckIn(address, roundId, game?.config.maxMissedCheckIns ?? 0);
  const { outcome } = useTally(roundId, round?.settled ?? false);
  const prize = usePrize(game?.stage === Stage.Ended);
  // Read only while a round is open: once settled, the events are the better source.
  const pendingTally = useLiveTally(round?.proposalId, !!round && !round.settled);
  const { sealed, markSealed } = useSealedLocally(round?.e3Id);
  const feeToken = useFeeToken();

  // A game that cannot be read is not a game that is loading. Collapsing the two leaves a wrong
  // NEXT_PUBLIC_GAME_ADDRESS, a dead RPC and a chain with no contract at that address all showing
  // the same spinner, which is the least diagnosable failure this app can produce.
  if (!isLoading && !game) {
    return (
      <main className="un">
        <div className="un-wrap" style={{ paddingTop: 80 }}>
          <section className="un-panel un-stack">
            <div className="un-label-dim">No game here</div>
            <h2 className="un-title">Nothing is deployed at this address</h2>
            <p className="un-note" style={{ maxWidth: "62ch" }}>
              The app is pointed at <span className="un-mono">{PUB_GAME_ADDRESS || "(unset)"}</span> on{" "}
              <span className="un-mono">{PUB_CHAIN_NAME}</span>, and the contract there did not answer. Either the
              address is stale, the RPC is unreachable, or the game was deployed to a different chain.
            </p>
            {error && <p className="un-fine">{error.message}</p>}
          </section>
        </div>
      </main>
    );
  }

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

  // Every write goes through here so a revert becomes a sentence rather than an unhandled promise
  // rejection. Reverts are ordinary in this game — a full tribe, a lobby short of its floor, a round
  // settled a second time — and none of them should surface as a crash.
  const send = async (label: string, run: () => Promise<unknown>) => {
    try {
      await run();
    } catch (e) {
      console.error(`${label}:`, e);
      addAlert(describeGameError(e), { type: "error" });
    }
  };

  const call = (functionName: "startGame" | "openRound" | "settleRound") =>
    send(functionName, () =>
      writeContractAsync({ address: PUB_GAME_ADDRESS, abi: SurvivalGameAbi, functionName, args: [] })
    );

  const joinTeam = () =>
    send("join", () =>
      writeContractAsync({
        address: PUB_GAME_ADDRESS,
        abi: SurvivalGameAbi,
        functionName: "join",
        args: [team],
      })
    );

  const capacity = game.config.teamCount * MAX_TEAM_SIZE;
  // Seats stay open until someone starts, so the button unlocks at the floor rather than at a full
  // lobby — waiting for the last joiner is how a lobby never plays.
  const canStart = game.alive.length >= game.config.minPlayers;

  return (
    <main className="un">
      {takeover && <CheckInTakeover state={checkIn} secondsLeft={secondsLeft} />}

      <Masthead game={game} address={address} pot={feeToken.format(game.pot)} symbol={feeToken.symbol} />

      <div className="un-wrap un-stack" style={{ gap: 18, paddingTop: 22 }}>
        {game.stage === Stage.Ended && game.winner !== ZERO_ADDRESS && (
          <section className="un-certificate">
            <div className="un-label" style={{ color: "var(--un-green)" }}>
              Settled · {game.roundCount} rounds
            </div>
            <h2 className="un-verdict" style={{ marginTop: 14 }}>
              The jury chose
            </h2>
            <p className="un-mono" style={{ fontSize: 21, color: "var(--un-fg)", marginTop: 6 }}>
              {shortAddress(game.winner)}
            </p>
            {/* The pot is already zero by the time this renders — settleRound pays out and clears it
                in the same call — so the figure comes from the payout event, not from `pot`. */}
            <div className="un-payout">
              <div className="un-payout-figure">{feeToken.format(prize ?? game.pot) ?? "—"}</div>
              <div className="un-label" style={{ color: "var(--un-ink)", marginTop: 6 }}>
                {feeToken.symbol ?? "tokens"} · paid out
              </div>
            </div>
          </section>
        )}

        {game.stage === Stage.Lobby && (
          <section className="un-panel un-stack">
            <div className="un-label-dim">
              Lobby · {game.alive.length} joined, {game.config.minPlayers} needed
            </div>
            <h2 className="un-title">Pick a tribe</h2>
            <p className="un-note" style={{ maxWidth: "62ch" }}>
              {game.config.teamCount} tribes. Every tribe needs at least {game.config.minMembersPerTeam}, and can
              hold up to {MAX_TEAM_SIZE} — so the game fits {game.config.minPlayers} to {capacity} players.{" "}
              {canStart
                ? "Enough have joined — anyone can start it now, and every seat still open stays empty for the whole game."
                : `${game.config.minPlayers - game.alive.length} more and anyone can start it.`}{" "}
              Nobody is in charge of starting: reaching the floor is an objective fact, not a privilege.
            </p>
            {canStart && game.alive.length <= game.config.mergeAt && (
              <p className="un-fine" style={{ maxWidth: "62ch", color: "var(--un-condemned-soft)" }}>
                Heads up: starting at {game.alive.length} is at or below the merge threshold of {game.config.mergeAt},
                so tribes dissolve immediately and every round is an individual vote. Start with more than{" "}
                {game.config.mergeAt} if you want tribal and council rounds.
              </p>
            )}
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
                disabled={isPending || !canStart}
                onClick={() => void call("startGame")}
              >
                Start the game
              </button>
            </div>
          </section>
        )}

        {round && (
          <RoundStatus
            round={round}
            tallyGrace={game.config.tallyGrace}
            owes={owes}
            tallyReady={!!pendingTally}
          />
        )}

        {isAlive && round && !round.settled && !checkIn.immature && (
          <CheckIn state={checkIn} secondsLeft={secondsLeft} />
        )}

        {/* The jury stage puts the survivors on trial rather than on the board. */}
        {game.stage === Stage.Jury && (
          <Finalists
            finalists={game.alive}
            teamOf={teamOf}
            jurors={game.jurors}
            roundCount={game.roundCount}
            self={address}
          />
        )}

        {round && (round.settled || pendingTally) && (
          <Reveal round={round} outcome={outcome} pending={pendingTally} self={address} />
        )}

        {/* Shown from the moment a round opens, and kept after it settles: the ciphertexts are the
            public half of a private ballot, and seeing them accumulate is what makes the privacy
            legible rather than merely asserted. */}
        {round && <Ciphertexts e3Id={round.e3Id} />}

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
          openSeats={game.stage === Stage.Lobby ? Math.max(0, game.config.minPlayers - game.alive.length) : 0}
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
              // Promoted once the counts exist: at that point settling is the only thing left to do,
              // and burying it reads as the round being stuck rather than waiting on a click.
              <button
                type="button"
                className={pendingTally ? "un-btn" : "un-btn un-btn-ghost un-btn-sm"}
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
            <span className="un-fine">
              {pendingTally && !round.settled
                ? "The counts are decrypted and on chain. Settling applies them — anyone can, and the result will not change."
                : "Anyone can do this. It is a clock, not a privilege."}
            </span>
          </div>
        )}
      </div>
    </main>
  );
}

/// The chrome. Ink, not cream — v3 has no light surfaces at all.
const Masthead = ({
  game,
  address,
  pot,
  symbol,
}: {
  game: { stage: Stage; alive: Address[]; jurors: Address[]; pot: bigint; roundCount: number };
  address?: Address;
  /// Already formatted, or undefined while the fee token's decimals are unknown.
  pot?: string;
  symbol?: string;
}) => (
  <header className="un-masthead">
    <h1 className="un-wordmark">UNRAVEL</h1>
    <div className="un-row" style={{ gap: 10 }}>
      <span className={`un-pill ${game.stage === Stage.Playing ? "un-pill-live" : ""}`}>
        {stageLabel(game.stage)}
      </span>
      <span className="un-pill">{game.alive.length} STILL BREATHING</span>
      {game.jurors.length > 0 && <span className="un-pill">{game.jurors.length} ON THE JURY</span>}
      {pot && (
        <span className="un-pill">
          POT {pot} {symbol ?? ""}
        </span>
      )}
      {address && (
        <span className="un-pill un-pill-live" title={address}>
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
