import { useState, type FC } from "react";
import type { Address } from "viem";
import { useReadContract, useReadContracts, useWriteContract } from "wagmi";
import { PUB_GAME_FACTORY_ADDRESS } from "@/constants";
import { useAlerts } from "@/context/Alerts";
import { GameFactoryAbi } from "../artifacts/GameFactory";
import { SurvivalGameAbi } from "../artifacts/SurvivalGame";
import { useActiveGame } from "../utils/activeGame";
import { useFeeToken } from "../hooks/useFeeToken";
import { Stage } from "../utils/gameTypes";
import { shortAddress } from "../utils/tribes";
import { describeGameError } from "../utils/errors";

const PAGE = 12;

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
            const stage = states?.[i * 3]?.result as number | undefined;
            const alive = states?.[i * 3 + 1]?.result as bigint | undefined;
            const config = states?.[i * 3 + 2]?.result as readonly unknown[] | undefined;
            const minPlayers = config ? Number(config[5]) : undefined;
            const entryFee = config ? (config[10] as bigint) : undefined;

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
                  {entryFee !== undefined &&
                    ` · ${entryFee === 0n ? "free" : `${feeToken.format(entryFee) ?? entryFee} ${feeToken.symbol ?? ""}`}`}
                </span>
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
  const [buyIn, setBuyIn] = useState("0");
  const [open, setOpen] = useState(false);

  const create = async () => {
    try {
      const decimals = feeToken.decimals ?? 6;
      const entryFee = BigInt(Math.round(Number(buyIn || "0") * 10 ** decimals));

      // Tribes of at least one, and a merge below the floor so tribal rounds actually happen —
      // starting at or under `mergeAt` dissolves the tribes before the first round.
      const teamCount = players >= 6 ? 3 : 2;
      const config = {
        campaignDuration: 900n,
        ballotDuration: 2700n,
        tallyGrace: 600n,
        teamCount,
        minMembersPerTeam: 1,
        minPlayers: players,
        lobbyTimeout: 86_400n,
        mergeAt: Math.max(2, Math.min(players - 1, 6)),
        finalists: 2,
        maxMissedCheckIns: 2,
        entryFee,
      };

      await writeContractAsync({
        address: PUB_GAME_FACTORY_ADDRESS,
        abi: GameFactoryAbi,
        functionName: "create",
        args: [config, name.trim() || "Unravel"],
      });

      // The new lobby is not selected automatically: the creator may be starting one for other
      // people, and silently moving them off the game they were watching is worse than a click.
      addAlert("Lobby created. Pick it from the list to join.", { type: "success", timeout: 5000 });
      setOpen(false);
      onCreated();
    } catch (e) {
      console.error("create lobby:", e);
      addAlert(describeGameError(e), { type: "error" });
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
          <span className="un-field-label">Buy-in ({feeToken.symbol ?? "tokens"})</span>
          <input className="un-input" value={buyIn} onChange={(e) => setBuyIn(e.target.value.replace(/[^0-9.]/g, ""))} />
        </label>
      </div>

      <p className="un-fine" style={{ maxWidth: "68ch" }}>
        Anyone can join, and anyone can start it once {players} have. The buy-in goes straight into
        the pot — and if the lobby never fills, anyone can cancel it after a day and every player
        takes their stake back.
      </p>

      <div className="un-row">
        <button type="button" className="un-btn" disabled={isPending} onClick={() => void create()}>
          {isPending ? "Creating…" : "Create"}
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
