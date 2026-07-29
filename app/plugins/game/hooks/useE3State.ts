import { useEffect, useState } from "react";
import { crispSdk } from "../utils/crispSdk";
import type { IRoundDetailsResponse } from "../utils/types";

export type E3State = {
  /// Server-side round status, e.g. "Active" / "Finished".
  status: string;
  /// True once the committee has published its key. Nothing can be encrypted before this.
  keyPublished: boolean;
  /// Ciphertexts accepted so far. Turnout is public; who voted for whom is not.
  voteCount: number;
  /// Unix seconds; the E3 input window, which is the ballot window.
  startTime: number;
  endTime: number;
};

/// Live E3 state from the CRISP coordination server.
///
/// The chain knows the round's timestamps, but only the server knows whether the committee has
/// actually published its key — and that is the difference between a ballot a voter can cast and
/// one that will fail. Surfacing it is the whole reason this hook exists: without it the UI shows
/// an open ballot window for several minutes during which every vote is impossible, with no
/// explanation.
export function useE3State(e3Id: bigint | undefined, pollMs = 10_000) {
  const [state, setState] = useState<E3State | undefined>();
  const [unavailable, setUnavailable] = useState(false);

  useEffect(() => {
    if (e3Id === undefined) return;
    let cancelled = false;

    const load = async () => {
      try {
        const raw = (await crispSdk.getRoundStateLite(Number(e3Id))) as unknown as IRoundDetailsResponse;
        if (cancelled) return;

        setState({
          status: raw.status,
          keyPublished: Array.isArray(raw.committee_public_key) && raw.committee_public_key.length > 0,
          voteCount: Number.parseInt(raw.vote_count ?? "0", 10) || 0,
          startTime: Number.parseInt(raw.start_time ?? "0", 10) || 0,
          endTime: Number.parseInt(raw.expiration ?? "0", 10) || 0,
        });
        setUnavailable(false);
      } catch {
        // The server 500s for a round it has not indexed yet, which is normal in the seconds after
        // a round opens. Treat it as "not known yet" rather than an error worth showing.
        if (!cancelled) setUnavailable(true);
      }
    };

    void load();
    const id = setInterval(load, pollMs);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [e3Id, pollMs]);

  return { e3: state, unavailable };
}
