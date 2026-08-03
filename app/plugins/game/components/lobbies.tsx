import { useState, type FC } from "react";
import type { Address } from "viem";
import { useReadContract, useReadContracts, useWriteContract } from "wagmi";
import { erc20Abi } from "viem";
import { PUB_GAME_FACTORY_ADDRESS, PUB_INTERFOLD_FEE_TOKEN_ADDRESS } from "@/constants";
import { useAlerts } from "@/context/Alerts";
import { GameFactoryAbi } from "../artifacts/GameFactory";
import { SurvivalGameAbi } from "../artifacts/SurvivalGame";
import { useActiveGame } from "../utils/activeGame";
import { useFeeToken } from "../hooks/useFeeToken";
import { Stage } from "../utils/gameTypes";
import { shortAddress } from "../utils/tribes";
import { describeGameError } from "../utils/errors";

const PAGE = 12;

/// Roughly what Interfold charges for one E3 at the Minimum committee, in whole fee tokens.
/// @dev Only used to warn — the real quote depends on the input window and the committee, and this
///      is deliberately a slight over-estimate so the warning errs towards "fund it more".
const FEE_PER_E3 = 14;

const FINALISTS = 2;

/// The knobs the form does not ask about, derived from the one it does.
///
/// `mergeAt` is capped at 6 so a long game still ends in a merge rather than staying tribal to the
/// last four, and floored at 2 so it never sits below `finalists`, which the constructor rejects.
function shapeFor(players: number) {
  return {
    teamCount: players >= 6 ? 3 : 2,
    mergeAt: Math.max(FINALISTS, Math.min(players - 1, 6)),
    finalists: FINALISTS,
  };
}

/// How many E3s a game of this shape will buy, which is what the pot has to cover before any of it
/// is prize money.
///
/// Not one per elimination: while the tribes are up, an elimination takes two rounds — everyone
/// votes a tribe to council, then that tribe alone votes one of its own out. After the merge it is
/// a single round, and the jury verdict is one more.
///
/// An upper bound, deliberately. A tribal round needs two tribes still standing, so a game that
/// wipes one out merges early and costs less; nothing here makes it cost more.
function expectedE3s(players: number): number {
  const { mergeAt, finalists } = shapeFor(players);
  const tribal = Math.max(0, players - mergeAt); // two E3s each
  const individual = Math.max(0, mergeAt - finalists); // one E3 each
  return Math.max(1, tribal * 2 + individual + 1);
}

/// The lobby browser: what exists, and how to start one.
///
/// Creating a game used to mean running a deploy script with a private key, which put it in the
/// hands of whoever operates the repository. This is the same operation as one transaction.
export const Lobbies: FC = () => {
  const { address: active, select } = useActiveGame();
  const feeToken = useFeeToken();

  const { data: count, refetch: refetchCount } = useReadContract({
    address: PUB_GAME_FACTORY_ADDRESS,
    abi: GameFactoryAbi,
    functionName: "gameCount",
    query: { enabled: !!PUB_GAME_FACTORY_ADDRESS, refetchInterval: 15_000 },
  });

  const { data: page, refetch: refetchPage } = useReadContract({
    address: PUB_GAME_FACTORY_ADDRESS,
    abi: GameFactoryAbi,
    functionName: "latest",
    args: [0n, BigInt(PAGE)],
    query: { enabled: !!PUB_GAME_FACTORY_ADDRESS, refetchInterval: 15_000 },
  });

  const addresses = ((page as Address[] | undefined) ?? []).filter(Boolean);

  // One multicall for every lobby's headline state, rather than a component each firing its own.
  const { data: states } = useReadContracts({
    contracts: addresses.flatMap((a) => [
      { address: a, abi: SurvivalGameAbi, functionName: "stage" as const },
      { address: a, abi: SurvivalGameAbi, functionName: "aliveCount" as const },
      { address: a, abi: SurvivalGameAbi, functionName: "config" as const },
      { address: a, abi: SurvivalGameAbi, functionName: "pot" as const },
    ]),
    query: { enabled: addresses.length > 0, refetchInterval: 15_000 },
  });

  if (!PUB_GAME_FACTORY_ADDRESS) {
    return (
      <section className="un-panel un-stack">
        <div className="un-label-dim">Lobbies</div>
        <p className="un-note">
          No factory is configured, so lobbies can only be created by deploying a game directly. Set
          NEXT_PUBLIC_GAME_FACTORY_ADDRESS to list and create them here.
        </p>
      </section>
    );
  }

  return (
    <section className="un-panel un-stack">
      <div className="un-spread">
        <div className="un-label">Lobbies</div>
        <span className="un-mono">{count?.toString() ?? "—"}</span>
      </div>

      <CreateLobby
        onCreated={() => {
          void refetchCount();
          void refetchPage();
        }}
      />

      {addresses.length === 0 ? (
        <p className="un-fine">Nobody has started one yet. Be the first.</p>
      ) : (
        <div className="un-stack" style={{ gap: 8 }}>
          {addresses.map((game, i) => {
            const stage = states?.[i * 4]?.result as number | undefined;
            const alive = states?.[i * 4 + 1]?.result as bigint | undefined;
            const config = states?.[i * 4 + 2]?.result as readonly unknown[] | undefined;
            const pot = states?.[i * 4 + 3]?.result as bigint | undefined;
            const minPlayers = config ? Number(config[5]) : undefined;
            const entryFee = config ? (config[10] as bigint) : undefined;

            // A lobby's pot can never open a round if it is empty, because the E3 fee is paid from
            // it. The factory refuses to create one, but a game deployed directly can be in this
            // state, and it is better said on the list than discovered when Start reverts.
            const empty = stage === Stage.Lobby && (pot ?? 0n) === 0n && entryFee === 0n;

            return (
              <button
                key={game}
                type="button"
                className={`un-option ${game === active ? "un-option-on" : ""}`}
                onClick={() => select(game)}
              >
                <span className="un-option-name">{shortAddress(game)}</span>
                <span className="un-lobby-meta">
                  {stageWord(stage)}
                  {alive !== undefined && minPlayers !== undefined && ` · ${alive}/${minPlayers}`}
                  {/* The pot, not the entry fee: what a player wants to know is what is on the
                      table, and joining is free. A lobby that still charges one says so. */}
                  {pot !== undefined && ` · ${feeToken.format(pot) ?? pot} ${feeToken.symbol ?? ""} pot`}
                  {entryFee !== undefined && entryFee !== 0n &&
                    ` · ${feeToken.format(entryFee) ?? entryFee} to join`}
                </span>
                {empty && <span className="un-tag un-tag-block">UNFUNDED</span>}
                {game === active && <span className="un-tag un-tag-you">VIEWING</span>}
              </button>
            );
          })}
        </div>
      )}
    </section>
  );
};

/// The create form.
///
/// Deliberately few fields. Everything here changes how a game plays, and the ones left out —
/// tribe count, merge point, finalists — are the ones a first-time creator has no basis to choose
/// and would get wrong. They keep the defaults the contract validates against.
const CreateLobby: FC<{ onCreated: () => void }> = ({ onCreated }) => {
  const { addAlert } = useAlerts();
  const { writeContractAsync, isPending } = useWriteContract();
  const feeToken = useFeeToken();

  const [name, setName] = useState("");
  const [players, setPlayers] = useState(6);
  const [open, setOpen] = useState(false);
  const [step, setStep] = useState<"idle" | "approving" | "creating">("idle");

  const rounds = expectedE3s(players);
  const needed = rounds * FEE_PER_E3;
  const sym = feeToken.symbol ?? "tokens";

  // Default to twice the fee bill: enough to run the game, with the other half as the prize. The
  // bare minimum is a valid lobby that pays its winner nothing, which is not what anyone means by
  // "start a game".
  //
  // Tracks the player count until the creator types their own figure — the suggestion is worthless
  // if it still reads "84" after they change a 6-player game to a 20-player one, and overwriting a
  // number somebody deliberately entered is worse than a stale suggestion.
  const [funding, setFunding] = useState<string | null>(null);
  const fundingValue = Number(funding ?? String(needed * 2)) || 0;
  const underfunded = fundingValue < needed;
  const prize = Math.max(0, fundingValue - needed);

  const create = async () => {
    try {
      const decimals = feeToken.decimals ?? 6;
      const amount = BigInt(Math.round(fundingValue * 10 ** decimals));

      // Tribes of at least one, and a merge below the floor so tribal rounds actually happen —
      // starting at or under `mergeAt` dissolves the tribes before the first round.
      //
      // `entryFee: 0` on purpose. The creator stands the whole pot, so joining costs a player
      // nothing but gas — no balance to acquire, no approval, no judgement about what a game is
      // worth before they have played one.
      const config = {
        campaignDuration: 900n,
        ballotDuration: 2700n,
        tallyGrace: 600n,
        minMembersPerTeam: 1,
        minPlayers: players,
        lobbyTimeout: 86_400n,
        maxMissedCheckIns: 2,
        entryFee: 0n,
        ...shapeFor(players),
      };

      // Two transactions, and the approval must be the factory rather than the game: the game does
      // not have an address until `create` runs. Sent unconditionally rather than after an
      // allowance read — one extra signature is cheaper than a stale allowance failing the create
      // and leaving the creator to guess why.
      setStep("approving");
      await writeContractAsync({
        address: PUB_INTERFOLD_FEE_TOKEN_ADDRESS,
        abi: erc20Abi,
        functionName: "approve",
        args: [PUB_GAME_FACTORY_ADDRESS, amount],
      });

      setStep("creating");
      await writeContractAsync({
        address: PUB_GAME_FACTORY_ADDRESS,
        abi: GameFactoryAbi,
        functionName: "create",
        args: [config, name.trim() || "Unravel", amount],
      });

      // The new lobby is not selected automatically: the creator may be starting one for other
      // people, and silently moving them off the game they were watching is worse than a click.
      addAlert("Lobby created and funded. Pick it from the list to join.", {
        type: "success",
        timeout: 5000,
      });
      setOpen(false);
      onCreated();
    } catch (e) {
      console.error("create lobby:", e);
      addAlert(describeGameError(e), { type: "error" });
    } finally {
      setStep("idle");
    }
  };

  if (!open) {
    return (
      <div className="un-row">
        <button type="button" className="un-btn" onClick={() => setOpen(true)}>
          Start a lobby
        </button>
      </div>
    );
  }

  return (
    <div className="un-panel-ink un-stack" style={{ gap: 12 }}>
      <div className="un-label-dim">New lobby</div>

      <div className="un-row" style={{ gap: 12 }}>
        <label className="un-field">
          <span className="un-field-label">Name</span>
          <input className="un-input" value={name} maxLength={24} placeholder="Unravel" onChange={(e) => setName(e.target.value)} />
        </label>

        <label className="un-field">
          <span className="un-field-label">Players to start</span>
          <input
            className="un-input"
            type="number"
            min={3}
            max={30}
            value={players}
            onChange={(e) => setPlayers(Math.max(3, Math.min(30, Number(e.target.value) || 3)))}
          />
        </label>

        <label className="un-field">
          <span className="un-field-label">You put up ({sym})</span>
          <input
            className="un-input"
            value={funding ?? String(needed * 2)}
            onChange={(e) => setFunding(e.target.value.replace(/[^0-9.]/g, ""))}
          />
        </label>
      </div>

      <p className="un-fine" style={{ maxWidth: "68ch" }}>
        Free to join. You stand the pot; everyone else needs nothing but gas. Anyone can start it
        once {players} have joined — and if it never fills, anyone can cancel after a day and you
        take your money back.
      </p>

      {/* The pot funds the game and the prize from the same pool, which is easy to get wrong in the
          direction of an unplayable lobby — so show the arithmetic rather than a verdict. */}
      <div className="un-stack" style={{ gap: 6, maxWidth: "68ch" }}>
        <p className="un-fine">
          A {players}-player game runs about {rounds} secret {rounds === 1 ? "ballot" : "ballots"},
          and each one costs roughly {FEE_PER_E3} {sym} to have the committee encrypt, tally and
          decrypt — <strong>{needed} {sym}</strong> in all, spent from the pot as the game goes.
        </p>
        <p className={underfunded ? "un-warn" : "un-fine"}>
          {underfunded
            ? fundingValue === 0
              ? `A lobby with an empty pot cannot open a single round.`
              : `${fundingValue} ${sym} runs out after ${Math.floor(fundingValue / FEE_PER_E3)} of ${rounds} ballots, so the game would stall part-way.`
            : `The winner takes what is left: about ${prize} ${sym}.`}
        </p>
      </div>

      <div className="un-row">
        <button
          type="button"
          className="un-btn"
          disabled={isPending || underfunded}
          onClick={() => void create()}
        >
          {step === "approving"
            ? `Approving ${fundingValue} ${sym}…`
            : step === "creating"
              ? "Creating…"
              : "Create and fund"}
        </button>
        <button type="button" className="un-btn un-btn-ghost" onClick={() => setOpen(false)}>
          Cancel
        </button>
      </div>
    </div>
  );
};

function stageWord(stage: number | undefined): string {
  switch (stage) {
    case Stage.Lobby:
      return "OPEN";
    case Stage.Playing:
      return "IN PLAY";
    case Stage.Jury:
      return "JURY";
    case Stage.Ended:
      return "SETTLED";
    case Stage.Cancelled:
      return "CANCELLED";
    default:
      return "—";
  }
}
