import { useState, type FC } from "react";
import type { Address } from "viem";
import { useAccount, useReadContract, useReadContracts, useWriteContract } from "wagmi";
import { erc20Abi } from "viem";
import {
  PUB_CRISP_VOTING_PLUGIN_ADDRESS,
  PUB_ENABLE_FAUCET,
  PUB_GAME_FACTORY_ADDRESS,
  PUB_INTERFOLD_FEE_TOKEN_ADDRESS,
} from "@/constants";
import { useFaucet } from "@/hooks/useFaucet";
import { useAlerts } from "@/context/Alerts";
import { GameFactoryAbi } from "../artifacts/GameFactory";
import { SurvivalGameAbi } from "../artifacts/SurvivalGame";
import { useActiveGame } from "../utils/activeGame";
import { publicClient } from "../utils/client";
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

/// The shortest campaign worth offering, in minutes.
///
/// Not a contract rule — the constructor only rejects zero. It is the committee: the ballot cannot
/// open until the DKG publishes its key, and a campaign shorter than that produces a round whose
/// ballot is already open by the time anyone can vote in it.
///
/// Configurable because the right value depends on how the ciphernodes are running, and the range
/// is wide. With full recursive proof aggregation a committee takes minutes; with aggregation
/// skipped it takes seconds. Five is a safe default for the former and far too conservative for
/// the latter — measure the first round and set this to what you actually observe.
const MIN_CAMPAIGN_MINUTES = Number(process.env.NEXT_PUBLIC_MIN_CAMPAIGN_MINUTES ?? 1);

/// Fallback for the plugin's own floor on ballot length, used only until the read lands. The real
/// value is read from the deployed plugin, because it is a setting rather than a constant and a
/// stale copy here would fail at `startGame` rather than in this form.
const FALLBACK_MIN_BALLOT_MINUTES = 3;

/// `minDuration()` alone. The plugin's full ABI is not among the artifacts this app syncs, and one
/// getter does not justify adding it.
const MIN_DURATION_ABI = [
  {
    type: "function",
    name: "minDuration",
    inputs: [],
    outputs: [{ type: "uint64" }],
    stateMutability: "view",
  },
] as const;

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
                  {/* Now that pacing varies per lobby it decides whether you can play at all: a
                      15+45 game is an evening, a 4-hour ballot is something you check in on. */}
                  {config !== undefined &&
                    ` · ${Number(config[0]) / 60}m talk + ${Number(config[1]) / 60}m vote`}
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
  const { address: creator } = useAccount();
  const feeToken = useFeeToken();

  const [name, setName] = useState("");
  const [players, setPlayers] = useState(6);
  // Defaults, not floors — both fields are free down to the minimums below. Chosen so the common
  // case is a game that finishes inside a meeting rather than an afternoon; a long async game is
  // two edits away.
  const [campaign, setCampaign] = useState(5);
  const [ballot, setBallot] = useState(10);
  const [open, setOpen] = useState(false);
  const [step, setStep] = useState<"idle" | "approving" | "creating">("idle");

  // The plugin refuses a proposal whose window is shorter than its own `minDuration`, and it does
  // so at `startGame` — after the lobby has been created, funded and filled. Read here so the floor
  // is enforced while it is still a number in a form.
  const { data: minDuration } = useReadContract({
    address: PUB_CRISP_VOTING_PLUGIN_ADDRESS,
    abi: MIN_DURATION_ABI,
    functionName: "minDuration",
    query: { enabled: !!PUB_CRISP_VOTING_PLUGIN_ADDRESS, staleTime: Infinity },
  });

  const minBallot = minDuration === undefined
    ? FALLBACK_MIN_BALLOT_MINUTES
    : Math.ceil(Number(minDuration) / 60);

  const campaignTooShort = campaign < MIN_CAMPAIGN_MINUTES;
  const ballotTooShort = ballot < minBallot;

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

  // What the creator can actually afford. Checked here rather than left to the transaction, because
  // the failure is otherwise an ERC20InsufficientBalance from a contract the form never mentions,
  // arriving after two wallet prompts.
  const { data: balance, refetch: refetchBalance } = useReadContract({
    address: PUB_INTERFOLD_FEE_TOKEN_ADDRESS,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: creator ? [creator] : undefined,
    query: { enabled: !!creator && !!PUB_INTERFOLD_FEE_TOKEN_ADDRESS },
  });

  const decimals = feeToken.decimals ?? 6;
  const held = balance === undefined ? undefined : Number(balance) / 10 ** decimals;
  const shortBy = held === undefined ? 0 : Math.max(0, fundingValue - held);

  const faucet = useFaucet();

  const create = async () => {
    if (!creator) {
      addAlert("Connect a wallet to start a lobby.", { type: "error" });
      return;
    }
    try {
      const amount = BigInt(Math.round(fundingValue * 10 ** decimals));

      // Tribes of at least one, and a merge below the floor so tribal rounds actually happen —
      // starting at or under `mergeAt` dissolves the tribes before the first round.
      //
      // `entryFee: 0` on purpose. The creator stands the whole pot, so joining costs a player
      // nothing but gas — no balance to acquire, no approval, no judgement about what a game is
      // worth before they have played one.
      const config = {
        campaignDuration: BigInt(campaign * 60),
        ballotDuration: BigInt(ballot * 60),
        // Not asked about: `tallyGrace` is the deadline after which a round the committee never
        // settled may be abandoned, which is a recovery knob rather than a pacing one. Ten minutes
        // past the ballot is generous for a committee that is working and short for one that is not.
        tallyGrace: 600n,
        minMembersPerTeam: 1,
        minPlayers: players,
        lobbyTimeout: 86_400n,
        maxMissedCheckIns: 2,
        entryFee: 0n,
        ...shapeFor(players),
      };

      // Two transactions, and the approval must be to the factory rather than the game: the game
      // does not have an address until `create` runs.
      //
      // Skipped when the allowance already covers it, because the common way to arrive here is a
      // second attempt after a failed create, and re-approving what is already approved is a
      // signature that buys nothing.
      const allowance = await publicClient.readContract({
        address: PUB_INTERFOLD_FEE_TOKEN_ADDRESS,
        abi: erc20Abi,
        functionName: "allowance",
        args: [creator, PUB_GAME_FACTORY_ADDRESS],
      });

      if (allowance < amount) {
        setStep("approving");
        const approval = await writeContractAsync({
          address: PUB_INTERFOLD_FEE_TOKEN_ADDRESS,
          abi: erc20Abi,
          functionName: "approve",
          args: [PUB_GAME_FACTORY_ADDRESS, amount],
        });

        // `writeContractAsync` resolves when the transaction is *sent*, not when it is mined. Going
        // straight into `create` means the wallet estimates gas against a chain where the approval
        // has not landed, so it fails with ERC20InsufficientAllowance before the create is ever
        // submitted — and the creator sees a revert on a transaction they never signed.
        await publicClient.waitForTransactionReceipt({ hash: approval });
      }

      setStep("creating");
      const created = await writeContractAsync({
        address: PUB_GAME_FACTORY_ADDRESS,
        abi: GameFactoryAbi,
        functionName: "create",
        args: [config, name.trim() || "Unravel", amount],
      });

      // Waited on for the same reason as the approval, with a different symptom: `gameCount` and
      // `latest` are read from the chain, so refetching them the instant the transaction is sent
      // returns the state from before it. The result was "Lobby created" sitting above "nobody has
      // started one yet" until the next poll came round.
      await publicClient.waitForTransactionReceipt({ hash: created });

      // The new lobby is not selected automatically: the creator may be starting one for other
      // people, and silently moving them off the game they were watching is worse than a click.
      addAlert("Lobby created and funded. Pick it from the list to join.", {
        type: "success",
        timeout: 5000,
      });
      setOpen(false);
      onCreated();
      void refetchBalance();
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
          <span className="un-field-label">
            You put up ({sym}){held !== undefined && ` · you hold ${held}`}
          </span>
          <input
            className="un-input"
            value={funding ?? String(needed * 2)}
            onChange={(e) => setFunding(e.target.value.replace(/[^0-9.]/g, ""))}
          />
        </label>
      </div>

      {/* The faucet lives in the nav, which is nowhere near the moment you discover you need it.
          Standing a pot is the only thing in this app that costs the fee token, so this is where
          running out actually happens. */}
      {shortBy > 0 && (
        <div className="un-row" style={{ gap: 10, alignItems: "baseline" }}>
          <p className="un-warn" style={{ margin: 0 }}>
            You hold {held} {sym} and need {shortBy} more.
          </p>
          {PUB_ENABLE_FAUCET && (
            <button
              type="button"
              className="un-btn un-btn-ghost"
              disabled={faucet.isConfirming}
              title={faucet.blockedReason}
              onClick={() => {
                if (!faucet.canClaim) {
                  addAlert(faucet.blockedReason ?? "Cannot claim from the faucet right now", {
                    type: "error",
                  });
                  return;
                }
                faucet.claim();
                // The claim's own confirmation does not know about this form's balance read.
                setTimeout(() => void refetchBalance(), 4000);
              }}
            >
              {faucet.isConfirming ? "Claiming…" : "Claim test tokens"}
            </button>
          )}
        </div>
      )}

      <div className="un-row" style={{ gap: 12 }}>
        <label className="un-field">
          <span className="un-field-label">Campaign (minutes)</span>
          <input
            className="un-input"
            type="number"
            min={MIN_CAMPAIGN_MINUTES}
            value={campaign}
            onChange={(e) => setCampaign(Math.max(1, Number(e.target.value) || 1))}
          />
        </label>

        <label className="un-field">
          <span className="un-field-label">Ballot (minutes)</span>
          <input
            className="un-input"
            type="number"
            min={minBallot}
            value={ballot}
            onChange={(e) => setBallot(Math.max(1, Number(e.target.value) || 1))}
          />
        </label>
      </div>

      {/* Both phases repeat every round, so this is the single biggest lever on what the game feels
          like to play — and the campaign is the half where the game actually happens. */}
      <p className={campaignTooShort || ballotTooShort ? "un-warn" : "un-fine"} style={{ maxWidth: "68ch" }}>
        {campaignTooShort
          ? `The campaign needs at least ${MIN_CAMPAIGN_MINUTES} ${MIN_CAMPAIGN_MINUTES === 1 ? "minute" : "minutes"}: the ballot cannot open until the committee has published its key, and a shorter window opens a ballot nobody can vote in yet.`
          : ballotTooShort
            ? `This deployment will not accept a ballot shorter than ${minBallot} minutes. A lobby created with less fails when someone tries to start it, not now.`
            : `Every round runs a ${campaign}-minute campaign and then a ${ballot}-minute ballot, so a round takes about ${campaign + ballot} minutes and the whole game around ${Math.round(((campaign + ballot) * rounds) / 60)} hours. The campaign is where the game is played — the ballot is mostly waiting.`}
      </p>

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
          // Blocked on the balance too: the alternative is two wallet prompts ending in a revert
          // from the token, which costs gas on the approval that did go through.
          disabled={isPending || underfunded || shortBy > 0 || campaignTooShort || ballotTooShort}
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
