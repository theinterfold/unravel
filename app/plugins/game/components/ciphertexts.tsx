import type { FC } from "react";
import { PUB_CHAIN } from "@/constants";
import { useInputs } from "../hooks/useInputs";

interface CiphertextsProps {
  e3Id: bigint;
}

/// The sealed ballots, as the chain has them.
///
/// This is the motif made literal: the cloud is completely legible and no dot in it is. Every entry
/// is a real published ciphertext with a real transaction behind it, and none of them says who sent
/// it, what it chose, or whether it was a vote at all.
///
/// The count is deliberately never called turnout, and the panel says why. Masks and re-votes both
/// produce entries, so the number genuinely is not the number of voters — which is the design's rule
/// about turnout being satisfied by fact rather than by omission. The relayer is the coordination
/// server for all of them, so even the sender column would be the same address every time; it is not
/// shown, because a column of one repeated address invites the reader to look for meaning in it.
export const Ciphertexts: FC<CiphertextsProps> = ({ e3Id }) => {
  const { inputs, isLoading } = useInputs(e3Id);
  const explorer = PUB_CHAIN.blockExplorers?.default.url;

  return (
    <section className="un-panel un-stack un-dotfield" style={{ gap: 12 }}>
      <div>
        <div className="un-spread">
          <div className="un-label">Sealed ballots on chain</div>
          <span className="un-mono" style={{ color: "var(--un-fg-2)" }}>
            {inputs.length}
          </span>
        </div>
        <p className="un-fine" style={{ marginTop: 8, maxWidth: "72ch" }}>
          Every sealed ballot lands here, and none of them can be read. This is not turnout: a mask
          makes an entry, and changing your vote makes another without removing the first — so this
          number is not the number of voters, and cannot be made into one.
        </p>
      </div>

      {isLoading && inputs.length === 0 && <p className="un-fine">Reading the chain…</p>}
      {!isLoading && inputs.length === 0 && <p className="un-fine">Nothing sealed yet.</p>}

      {inputs.length > 0 && (
        <div className="un-stack" style={{ gap: 6 }}>
          {inputs.map((input) => (
            <div key={`${input.txHash}-${input.index}`} className="un-cipher-row">
              <span className="un-cipher-index">#{String(input.index).padStart(2, "0")}</span>
              <span className="un-cipher-hash" title={input.inputHash.toString()}>
                {shortHex(input.inputHash)}
              </span>
              {explorer && input.txHash ? (
                <a
                  className="un-cipher-tx"
                  href={`${explorer}/tx/${input.txHash}`}
                  target="_blank"
                  rel="noreferrer"
                >
                  {shortTx(input.txHash)} →
                </a>
              ) : (
                <span className="un-cipher-tx">{shortTx(input.txHash)}</span>
              )}
            </div>
          ))}
        </div>
      )}
    </section>
  );
};

/// The commitment, as hex. Truncated because the full 32 bytes tell a reader nothing more than the
/// first few do — the point is that it is opaque, not that it is long.
function shortHex(value: bigint): string {
  const hex = value.toString(16).padStart(64, "0");
  return `0x${hex.slice(0, 8)}…${hex.slice(-6)}`;
}

function shortTx(hash: string): string {
  if (!hash) return "—";
  return `${hash.slice(0, 10)}…${hash.slice(-6)}`;
}
