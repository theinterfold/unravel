import { useState, type FC } from "react";
import type { Address } from "viem";
import { uploadToPinata } from "@/utils/ipfs";
import { useAlerts } from "@/context/Alerts";
import { useCampaignFeed, useCampaignActions } from "../hooks/useCampaign";
import { shortAddress, sameAddress } from "../utils/tribes";

interface CampaignProps {
  round: number;
  /// Whether the connected wallet may post (a voter, during the campaign window).
  canPost: boolean;
  self?: Address;
  /// Still readable after the window closes — just not writable.
  closed?: boolean;
}

/// The public half of a round.
///
/// Everything here is attributable and permanent. That asymmetry against the sealed ballot is the
/// game: a promise made here costs nothing to break, and cannot be proven broken.
export const Campaign: FC<CampaignProps> = ({ round, canPost, self, closed }) => {
  const { posts, isLoading } = useCampaignFeed(round);
  const { post, isPending } = useCampaignActions();
  const { addAlert } = useAlerts();
  const [draft, setDraft] = useState("");

  const submit = async () => {
    if (!draft.trim()) return;
    try {
      const cid = await uploadToPinata(JSON.stringify({ body: draft, round }));
      await post(cid);
      setDraft("");
      addAlert("Posted.", { type: "success", timeout: 3000 });
    } catch (e) {
      console.error("campaign post:", e);
      addAlert(e instanceof Error ? e.message : "Could not post", { type: "error" });
    }
  };

  return (
    <section className="un-panel un-stack">
      <div className="un-spread">
        <div className="un-label-dim">
          Campaign · round {String(round + 1).padStart(2, "0")}
          {closed ? " · closed, still readable" : ""}
        </div>
      </div>

      <p className="un-fine" style={{ maxWidth: "68ch" }}>
        Public and signed with your name. Say what you like — you are not bound by it, and nobody can prove you broke
        it.
      </p>

      {canPost && (
        <div className="un-stack" style={{ gap: 10 }}>
          <textarea
            className="un-textarea"
            value={draft}
            maxLength={2000}
            placeholder="Make your case."
            onChange={(e) => setDraft(e.target.value)}
          />
          <div className="un-row">
            <button
              type="button"
              className="un-btn"
              disabled={isPending || !draft.trim()}
              onClick={() => void submit()}
            >
              {isPending ? "Posting…" : "Post"}
            </button>
            <span className="un-fine">Signed, permanent, and on the record.</span>
          </div>
        </div>
      )}

      <div className="un-stack" style={{ gap: 10 }}>
        {isLoading && posts.length === 0 && <p className="un-fine">Loading…</p>}
        {!isLoading && posts.length === 0 && <p className="un-fine">Nobody has said anything yet.</p>}
        {posts.map((entry) => (
          <article key={`${entry.player}-${entry.blockNumber}-${entry.cid}`} className="un-panel-ink">
            <div className="un-row" style={{ gap: 10, marginBottom: 8 }}>
              <span className="un-mono" style={{ color: "var(--un-fg-2)", fontSize: 13 }}>
                {shortAddress(entry.player)}
              </span>
              {sameAddress(entry.player, self) && <span className="un-tag un-tag-you">YOU</span>}
              <span className="un-mono" style={{ marginLeft: "auto", fontSize: 10.5, color: "var(--un-dim-2)" }}>
                BLOCK {entry.blockNumber.toString()}
              </span>
            </div>
            <CampaignBody cid={entry.cid} />
          </article>
        ))}
      </div>
    </section>
  );
};

/// Posts are stored off-chain; the event only carries the pointer.
///
/// The CID is rendered as the CID rather than dressed up as a message, because fetching it is a
/// separate concern and a half-loaded feed that silently shows nothing is worse than one that shows
/// exactly what the chain has.
const CampaignBody: FC<{ cid: string }> = ({ cid }) => (
  <p className="un-mono" style={{ fontSize: 12, wordBreak: "break-all", color: "var(--un-fg-3)" }}>
    {cid}
  </p>
);
