import { useEffect, useState } from "react";
import { useAccount, useReadContract, useWriteContract } from "wagmi";
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
import { Lobbies } from "../components/lobbies";
import { History } from "../components/history";
import { useNames, useSetName } from "../hooks/useNames";
import { useNotifications, useAnnounce } from "../hooks/useNotifications";
import { Finalists } from "../components/finalists";
import { MAX_TEAM_SIZE, RoundKind, Stage, ZERO_ADDRESS } from "../utils/gameTypes";
import { useGameAddress } from "../utils/activeGame";
import { shortAddress, sameAddress, tribe } from "../utils/tribes";
import { describeGameError } from "../utils/errors";
import { useAlerts } from "@/context/Alerts";
import type { Address } from "viem";

export default function GamePage() {
  const { address } = useAccount();
  const activeGame = useGameAddress();
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
  const names = useNames(allPlayers);
  const notifications = useNotifications();
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

  // With no default game configured, the first thing anybody sees is the browser rather than an
  // error about an address that was never meant to hold a contract.
  if (!activeGame) {
    return (
      <main className="un">
        <Masthead game={EMPTY_GAME} address={address} />
        <div className="un-wrap un-stack" style={{ gap: 18, paddingTop: 22 }}>
          <section className="un-panel un-stack">
            <div className="un-label-dim">No lobby selected</div>
            <h2 className="un-verdict">Pick a game, or start one.</h2>
            <p className="un-prose">
              Every lobby is its own game with its own pot, funded by the people who join it. Nobody
              runs them — anyone can start one, anyone can join, and anyone can start the game once
              it is full enough.
            </p>
          </section>
          <Lobbies />
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

  // Only the two moments a player loses the game by missing, and only when they apply to them.
  useAnnounce(canVote && !sealed ? `ballot-${round?.id}` : undefined, () =>
    notifications.notify("The ballot is open", "You have a vote to cast this round.")
  );
  useAnnounce(owesCheckIn && round ? `checkin-${round.id}` : undefined, () =>
    notifications.notify("Check in", "Miss too many and you are out — one tap, no proof.")
  );
  // Mirrors the contract: settling waits on the tally existing, not on a clock. The only clock
  // condition left is that the ballot has closed — nobody settles a round people can still vote in.
  const settleDue = !!round && !round.settled && now >= round.ballotClosesAt && !!pendingTally;
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

        <Lobbies />

        <PlayerSettings notifications={notifications} />

        {game.stage === Stage.Cancelled && <CancelledLobby self={address} feeToken={feeToken} />}

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

        {game.roundCount > 0 && <History roundCount={game.roundCount} players={allPlayers} />}

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
        {round && (settleDue || (round.settled && game.stage !== Stage.Ended)) && (
          <div className="un-row">
            {settleDue && (
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
              {settleDue
                ? "The counts are decrypted and on chain. Settling applies them — anyone can, and the result will not change."
                : "Anyone can settle a round or open the next one. It is a clock, not a privilege."}
            </span>
          </div>
        )}
      </div>
    </main>
  );
}

/// Name and notifications: the two things a player sets once and then forgets about.
const PlayerSettings = ({
  notifications,
}: {
  notifications: ReturnType<typeof useNotifications>;
}) => {
  const { setName, isPending, configured } = useSetName();
  const { addAlert } = useAlerts();
  const [draft, setDraft] = useState("");

  const save = async () => {
    try {
      await setName(draft.trim());
      addAlert("Name set.", { type: "success", timeout: 3000 });
      setDraft("");
    } catch (e) {
      console.error("setName:", e);
      addAlert(describeGameError(e), { type: "error" });
    }
  };

  if (!configured && notifications.permission === "unsupported") return null;

  return (
    <section className="un-panel un-row" style={{ gap: 12 }}>
      {configured && (
        <>
          <input
            className="un-input"
            style={{ maxWidth: 220 }}
            value={draft}
            maxLength={24}
            placeholder="Set a display name"
            onChange={(e) => setDraft(e.target.value)}
          />
          <button
            type="button"
            className="un-btn un-btn-ghost un-btn-sm"
            disabled={isPending || !draft.trim()}
            onClick={() => void save()}
          >
            {isPending ? "Saving…" : "Save"}
          </button>
        </>
      )}

      {notifications.permission === "default" && (
        <button type="button" className="un-btn un-btn-ghost un-btn-sm" onClick={() => void notifications.request()}>
          Notify me when it is my turn
        </button>
      )}
      {notifications.permission === "granted" && <span className="un-fine">Notifications on.</span>}
      {notifications.permission === "denied" && (
        <span className="un-fine">Notifications blocked — the clock is the only warning.</span>
      )}
    </section>
  );
};

/// A lobby that never filled. The entry fees are sitting in the contract waiting to be claimed, so
/// the only thing this screen does is say so and hand them back.
const CancelledLobby = ({
  self,
  feeToken,
}: {
  self?: Address;
  feeToken: { format: (v: bigint | undefined) => string | undefined; symbol?: string };
}) => {
  const { addAlert } = useAlerts();
  const { writeContractAsync, isPending } = useWriteContract();

  const { data: refund, refetch } = useReadContract({
    address: PUB_GAME_ADDRESS,
    abi: SurvivalGameAbi,
    functionName: "refundOf",
    args: self ? [self] : undefined,
    query: { enabled: !!self },
  });

  const owed = (refund as bigint | undefined) ?? 0n;

  const claim = async () => {
    try {
      await writeContractAsync({
        address: PUB_GAME_ADDRESS,
        abi: SurvivalGameAbi,
        functionName: "claimRefund",
        args: [],
      });
      void refetch();
      addAlert("Refunded.", { type: "success", timeout: 3000 });
    } catch (e) {
      console.error("claimRefund:", e);
      addAlert(describeGameError(e), { type: "error" });
    }
  };

  return (
    <section className="un-panel un-stack">
      <div className="un-label-dim">Lobby cancelled</div>
      <h2 className="un-verdict">Nobody came.</h2>
      <p className="un-prose">
        The lobby sat unfilled past its deadline, so it was closed and the entry fees released.
        Anyone could do that — a lobby&apos;s money is not left waiting on whoever created it.
      </p>
      {owed > 0n ? (
        <div className="un-row">
          <button type="button" className="un-btn" disabled={isPending} onClick={() => void claim()}>
            {isPending ? "Claiming…" : `Claim ${feeToken.format(owed) ?? owed.toString()} ${feeToken.symbol ?? ""}`}
          </button>
        </div>
      ) : (
        <p className="un-fine">{self ? "Nothing owed to this address." : "Connect a wallet to check for a refund."}</p>
      )}
    </section>
  );
};

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

/// A masthead needs a shape even when no game is selected.
const EMPTY_GAME = { stage: Stage.Lobby, alive: [], jurors: [], pot: 0n, roundCount: 0 };

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
    case Stage.Cancelled:
      return "CANCELLED";
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
