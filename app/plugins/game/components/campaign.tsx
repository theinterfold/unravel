import { useState, type FC } from "react";
import type { Address } from "viem";
import { Button, TextAreaRichText } from "@aragon/ods";
import { AddressText } from "@/components/text/address";
import { uploadToPinata } from "@/utils/ipfs";
import { useAlerts } from "@/context/Alerts";
import { useCampaignFeed, useCampaignActions } from "../hooks/useCampaign";

interface CampaignProps {
  round: number;
  /// Whether the connected wallet may post (a voter, during the campaign window).
  canPost: boolean;
  self?: Address;
}

/// The public half of a round.
///
/// Everything here is attributable and permanent. That asymmetry against the secret ballot is the
/// game: a promise made here costs nothing to break, and cannot be proven broken.
export const Campaign: FC<CampaignProps> = ({ round, canPost, self }) => {
  const { posts, isLoading } = useCampaignFeed(round);
  const { post, checkIn, isPending } = useCampaignActions();
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
    <div className="box-border flex w-full flex-col gap-4 rounded-xl border border-neutral-100 bg-neutral-0 p-4 xl:p-6">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-lg font-semibold text-neutral-800">Campaign</h2>
          <p className="text-sm text-neutral-500">
            Public and signed with your name. Say what you like — you are not bound by it.
          </p>
        </div>
        <Button size="sm" variant="tertiary" disabled={isPending} onClick={() => checkIn()}>
          Check in
        </Button>
      </div>

      {canPost && (
        <div className="flex flex-col gap-2">
          <TextAreaRichText value={draft} onChange={(value: string) => setDraft(value ?? "")} />
          <div>
            <Button size="md" disabled={isPending || !draft.trim()} onClick={submit}>
              {isPending ? "Posting..." : "Post"}
            </Button>
          </div>
        </div>
      )}

      <div className="flex flex-col gap-3">
        {isLoading && posts.length === 0 && <p className="text-sm text-neutral-500">Loading...</p>}
        {!isLoading && posts.length === 0 && <p className="text-sm text-neutral-500">Nobody has said anything yet.</p>}
        {posts.map((entry) => (
          <div key={`${entry.player}-${entry.blockNumber}-${entry.cid}`} className="rounded-lg bg-neutral-50 p-3">
            <div className="mb-1 flex items-center gap-2 text-xs text-neutral-500">
              <AddressText asLink={false}>{entry.player}</AddressText>
              {self && entry.player.toLowerCase() === self.toLowerCase() && (
                <span className="rounded bg-primary-100 px-2 py-0.5 text-primary-700">you</span>
              )}
            </div>
            <CampaignBody cid={entry.cid} />
          </div>
        ))}
      </div>
    </div>
  );
};

/// Posts are stored off-chain; the event only carries the pointer.
const CampaignBody: FC<{ cid: string }> = ({ cid }) => <p className="break-all text-sm text-neutral-700">{cid}</p>;
