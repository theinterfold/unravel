import { useEffect, useState, type FC } from "react";
import type { Address } from "viem";
import { uploadToPinata, fetchIpfsAsJson } from "@/utils/ipfs";
import { useAlerts } from "@/context/Alerts";
import { useCampaignFeed, useCampaignActions } from "../hooks/useCampaign";
import { sameAddress } from "../utils/tribes";
import { useNames, displayName } from "../hooks/useNames";
import { describeGameError } from "../utils/errors";

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
  const names = useNames(posts.map((p) => p.player));

  const submit = async () => {
    const body = draft.trim();
    if (!body) return;

    try {
      let pointer: string;
      try {
        pointer = await uploadToPinata(JSON.stringify({ body, round }));
      } catch (e) {
        // Pinning is optional. Without a PINATA_JWT the post goes on chain inline instead — the
        // event already makes it permanent and attributable either way, and IPFS is a size and gas
        // optimisation rather than the thing that gives a post its weight. Only this specific
        // failure falls back; a real pinning outage still surfaces, because silently changing where
        // data lives is worse than saying so.
        if (!isPinningUnconfigured(e)) throw e;
        if (body.length > INLINE_LIMIT) {
          throw new Error(
            `Pinning is not configured, so posts are stored on chain and capped at ${INLINE_LIMIT} characters. This one is ${body.length}.`
          );
        }
        pointer = `${INLINE_PREFIX}${body}`;
      }

      // `post` now resolves on the receipt, so by here the Posted event exists and the feed's next
      // poll will contain it. Announcing before that put the confirmation above a feed that did not.
      await post(pointer);
      setDraft("");
      addAlert("Posted.", { type: "success", timeout: 3000 });
    } catch (e) {
      console.error("campaign post:", e);
      addAlert(describeGameError(e), { type: "error" });
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
              {isPending ? "Posting… (waiting for the chain)" : "Post"}
            </button>
            <span className="un-fine">
              Signed, permanent, and on the record.
              {draft.trim().length > 0 && ` ${draft.trim().length}/${INLINE_LIMIT} if stored on chain.`}
            </span>
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
                {displayName(entry.player, names)}
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

/// Inline posts are prefixed so a reader can tell them from an IPFS pointer without guessing at the
/// shape of a CID.
const INLINE_PREFIX = "text:";
/// Inline posts are calldata, so they are capped. Generous enough for a case, short enough that a
/// player cannot accidentally spend a fortune making it.
const INLINE_LIMIT = 500;

function isPinningUnconfigured(error: unknown): boolean {
  return error instanceof Error && /not configured/i.test(error.message);
}

/// What a player actually wrote.
///
/// Two storage shapes reach this: an inline post, which is already the text, and an IPFS pointer,
/// which has to be fetched. A failed fetch falls back to showing the raw pointer rather than an
/// empty bubble — the chain's record is still there even when the gateway is not.
const CampaignBody: FC<{ cid: string }> = ({ cid }) => {
  const inline = cid.startsWith(INLINE_PREFIX);
  const [body, setBody] = useState<string | undefined>(inline ? cid.slice(INLINE_PREFIX.length) : undefined);
  const [failed, setFailed] = useState(false);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    if (inline) return;
    let cancelled = false;

    fetchIpfsAsJson(cid)
      .then((data: { body?: string }) => {
        if (!cancelled) setBody(typeof data?.body === "string" ? data.body : undefined);
      })
      .catch((e) => {
        // Logged, because the two causes look identical on screen and need different fixes: no
        // gateways configured at all, versus every configured gateway failing to serve the CID.
        console.error(`campaign post ${cid}:`, e);
        if (!cancelled) setFailed(true);
      });

    return () => {
      cancelled = true;
    };
  }, [cid, inline, attempt]);

  if (body) return <p style={{ fontSize: 14, lineHeight: 1.6, color: "var(--un-fg-2)" }}>{body}</p>;

  return (
    <p className="un-mono" style={{ fontSize: 12, wordBreak: "break-all", color: "var(--un-dim)" }}>
      {failed ? "unreachable · " : "loading · "}
      {cid}
      {/* A fresh pin can take a moment to become servable, so the first read of a just-posted
          message can fail on timing alone. Without this the post stays dead until a reload. */}
      {failed && (
        <button
          type="button"
          className="un-link"
          style={{ marginLeft: 8 }}
          onClick={() => {
            setFailed(false);
            setAttempt((a) => a + 1);
          }}
        >
          retry
        </button>
      )}
    </p>
  );
};
