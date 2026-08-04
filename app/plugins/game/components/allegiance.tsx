import { useState, type FC } from "react";
import { encodeAbiParameters, erc20Abi, keccak256, type Address, type Hex } from "viem";
import { useAccount, useReadContract, useWriteContract } from "wagmi";
import { PUB_INTERFOLD_FEE_TOKEN_ADDRESS } from "@/constants";
import { publicClient } from "../utils/client";
import { useAlerts } from "@/context/Alerts";
import { SecretAllegianceAbi } from "../artifacts/SecretAllegiance";
import { useGameTx, txLabel } from "../hooks/useGameTx";
import { useFeeToken } from "../hooks/useFeeToken";
import { displayName } from "../hooks/useNames";
import { Stage } from "../utils/gameTypes";
import { sameAddress } from "../utils/tribes";

interface AllegianceProps {
  contract: Address;
  stage: Stage;
  /// Everyone who could still win — the roster while in lobby, the survivors later.
  candidates: Address[];
  names: Record<string, string>;
  self?: Address;
  winner?: Address;
}

/// The only thing in this game that nobody else knows.
///
/// Everything else is public — the roster, the tally, who protected whom. That is why the optimal
/// line is to be agreeable: with no private information there is nothing to deduce and nothing to
/// lie about. One hidden pick each, with money on it, gives every player a motive they have to
/// conceal and the campaign something to actually be about.
const KEY_PREFIX = "unravel.allegiance.";

type Stored = { pick: Address; salt: Hex };

function load(contract: Address, self: Address): Stored | undefined {
  try {
    const raw = window.localStorage.getItem(`${KEY_PREFIX}${contract}.${self}`.toLowerCase());
    return raw ? (JSON.parse(raw) as Stored) : undefined;
  } catch {
    return undefined;
  }
}

function save(contract: Address, self: Address, value: Stored) {
  window.localStorage.setItem(
    `${KEY_PREFIX}${contract}.${self}`.toLowerCase(),
    JSON.stringify(value)
  );
}

export const Allegiance: FC<AllegianceProps> = ({
  contract,
  stage,
  candidates,
  names,
  self,
  winner,
}) => {
  const { writeContractAsync } = useWriteContract();
  const { addAlert } = useAlerts();
  const tx = useGameTx();
  const feeToken = useFeeToken();
  const [choice, setChoice] = useState<Address | undefined>();
  const [topUp, setTopUp] = useState("");
  const { address: wallet } = useAccount();

  const { data: commitment, refetch: refetchCommitment } = useReadContract({
    address: contract,
    abi: SecretAllegianceAbi,
    functionName: "commitmentOf",
    args: self ? [self] : undefined,
    query: { enabled: !!self, refetchInterval: 15_000 },
  });

  const { data: pool, refetch: refetchPool } = useReadContract({
    address: contract,
    abi: SecretAllegianceAbi,
    functionName: "pool",
    query: { refetchInterval: 15_000 },
  });

  const { data: revealed, refetch: refetchRevealed } = useReadContract({
    address: contract,
    abi: SecretAllegianceAbi,
    functionName: "revealedPick",
    args: self ? [self] : undefined,
    query: { enabled: !!self && stage === Stage.Ended, refetchInterval: 15_000 },
  });

  const committed = !!commitment && commitment !== `0x${"0".repeat(64)}`;
  const stored = self ? load(contract, self) : undefined;
  const alreadyRevealed = !!revealed && revealed !== "0x0000000000000000000000000000000000000000";

  const commit = async () => {
    if (!self || !choice) return;
    // Random salt, kept only here. Without it a ten-address roster is brute-forced instantly.
    const bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    const salt = `0x${Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")}` as Hex;
    // Bound to the committer, not just the pick: commitments are public, so an unbound hash could
    // be copied and replayed by anyone once the original revealed it.
    const hash = keccak256(
      encodeAbiParameters(
        [{ type: "address" }, { type: "address" }, { type: "bytes32" }],
        [self, choice, salt]
      )
    );

    // Saved *before* the transaction, not after. If it lands and the write did not happen, the
    // player can never reveal and their stake is lost — an extra key on a failed commit is free.
    save(contract, self, { pick: choice, salt });

    const ok = await tx.run("commit", () =>
      writeContractAsync({
        address: contract,
        abi: SecretAllegianceAbi,
        functionName: "commit",
        args: [hash],
      })
    );
    if (ok) {
      addAlert("Backed. Nobody can see who.", { type: "success", timeout: 4000 });
      void refetchCommitment();
    }
  };

  const reveal = async () => {
    if (!stored) return;
    const ok = await tx.run("reveal", () =>
      writeContractAsync({
        address: contract,
        abi: SecretAllegianceAbi,
        functionName: "reveal",
        args: [stored.pick, stored.salt],
      })
    );
    if (ok) void refetchRevealed();
  };

  /// Anyone can fund, any time. Exposed here because an unfunded pool makes the whole mechanic
  /// roleplay — the hidden pick still exists, but nothing rides on it, which is most of the point.
  const fund = async () => {
    if (!wallet) return;
    const decimals = feeToken.decimals ?? 6;
    const amount = BigInt(Math.round((Number(topUp) || 0) * 10 ** decimals));
    if (amount === 0n) return;

    const allowance = await publicClient.readContract({
      address: PUB_INTERFOLD_FEE_TOKEN_ADDRESS,
      abi: erc20Abi,
      functionName: "allowance",
      args: [wallet, contract],
    });

    if (allowance < amount) {
      const approval = await tx.run("approve", () =>
        writeContractAsync({
          address: PUB_INTERFOLD_FEE_TOKEN_ADDRESS,
          abi: erc20Abi,
          functionName: "approve",
          args: [contract, amount],
        })
      );
      if (!approval) return;
    }

    const ok = await tx.run("fund", () =>
      writeContractAsync({
        address: contract,
        abi: SecretAllegianceAbi,
        functionName: "fund",
        args: [amount],
      })
    );
    if (ok) {
      setTopUp("");
      addAlert("Added to the side pot.", { type: "success", timeout: 4000 });
      void refetchPool();
    }
  };

  const claim = () =>
    tx.run("claim", () =>
      writeContractAsync({
        address: contract,
        abi: SecretAllegianceAbi,
        functionName: "claim",
        args: [],
      })
    );

  const prize = feeToken.format(pool as bigint | undefined);
  const others = candidates.filter((c) => !sameAddress(c, self));

  return (
    <section className="un-panel un-stack">
      <div className="un-spread">
        <div className="un-label-dim">Allegiance · nobody sees this</div>
        {prize && (
          <span className="un-mono">
            {prize} {feeToken.symbol ?? ""}
          </span>
        )}
      </div>

      {stage !== Stage.Ended && (
        <div className="un-row" style={{ gap: 10 }}>
          <input
            className="un-input"
            style={{ maxWidth: 140 }}
            value={topUp}
            placeholder="0"
            onChange={(e) => setTopUp(e.target.value.replace(/[^0-9.]/g, ""))}
          />
          <button
            type="button"
            className="un-btn un-btn-ghost un-btn-sm"
            disabled={tx.isBusy || !Number(topUp)}
            onClick={() => void fund()}
          >
            {txLabel(tx.phase, `Add ${feeToken.symbol ?? "tokens"} to the pot`)}
          </button>
          <span className="un-fine">
            {(pool as bigint | undefined) ? "Anyone can add to it." : "Empty — nothing rides on anyone's pick yet."}
          </span>
        </div>
      )}

      {stage === Stage.Lobby && !committed && (
        <>
          <p className="un-prose">
            Back someone to win the whole thing. Your pick is sealed until the game ends, and the
            side pot splits between everyone who called it right — so you have a reason to steer the
            game that nobody else can see.
          </p>
          <div className="un-stack" style={{ gap: 8 }}>
            {others.map((player) => (
              <button
                key={player}
                type="button"
                className={`un-option ${sameAddress(player, choice) ? "un-option-on" : ""}`}
                onClick={() => setChoice(player)}
              >
                <span className="un-option-name">{displayName(player, names)}</span>
              </button>
            ))}
          </div>
          <div className="un-row">
            <button
              type="button"
              className="un-btn"
              disabled={!choice || tx.isBusy}
              onClick={() => void commit()}
            >
              {txLabel(tx.phase, "Back them, secretly")}
            </button>
            <span className="un-fine">
              One pick, unchangeable, before the game starts. Kept in this browser — clear your
              storage and you cannot claim.
            </span>
          </div>
        </>
      )}

      {stage === Stage.Lobby && committed && (
        <p className="un-prose">
          Your pick is sealed{stored ? ` — you backed ${displayName(stored.pick, names)}.` : "."}{" "}
          Nobody else can see it, including us.
        </p>
      )}

      {stage !== Stage.Lobby && stage !== Stage.Ended && (
        <p className="un-prose">
          {committed
            ? stored
              ? `You are quietly backing ${displayName(stored.pick, names)}. Get them to the end.`
              : "You have a sealed pick, but this browser has lost the key to it. You will not be able to reveal."
            : "You did not back anyone before the game started."}
        </p>
      )}

      {stage === Stage.Ended && (
        <>
          <p className="un-prose">
            {alreadyRevealed
              ? sameAddress(revealed as Address, winner)
                ? "You called it. Take your share."
                : `You backed ${displayName(revealed as Address, names)}, who did not win.`
              : committed
                ? stored
                  ? `Reveal to prove you backed ${displayName(stored.pick, names)}.`
                  : "This browser lost the key to your pick, so it cannot be revealed."
                : "You had nothing riding on this one."}
          </p>
          <div className="un-row">
            {committed && stored && !alreadyRevealed && (
              <button type="button" className="un-btn" disabled={tx.isBusy} onClick={() => void reveal()}>
                {txLabel(tx.phase, "Reveal my pick")}
              </button>
            )}
            {alreadyRevealed && sameAddress(revealed as Address, winner) && (
              <button type="button" className="un-btn" disabled={tx.isBusy} onClick={() => void claim()}>
                {txLabel(tx.phase, "Claim my share")}
              </button>
            )}
          </div>
        </>
      )}
    </section>
  );
};
