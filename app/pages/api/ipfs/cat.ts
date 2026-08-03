import type { NextApiRequest, NextApiResponse } from "next";

/**
 * Server-side read proxy for content this app pinned.
 *
 * Public gateways are a bad way to read back your own pins. `gateway.pinata.cloud` is rate limited
 * and increasingly restricted to dedicated-gateway customers, and `ipfs.io` / `dweb.link` have to
 * find the content on the DHT first — which for a block pinned seconds ago by one provider can take
 * minutes or simply never resolve. The result in the browser is a campaign post that reads
 * "unreachable" while the pin is perfectly healthy.
 *
 * Reading through here instead removes three failure modes at once: the request is authenticated,
 * so Pinata serves its own customer's content directly; it runs on the server, so no CORS; and it
 * can be patient in a way a browser fetch behind a 5s abort cannot.
 *
 * Public gateways stay as a fallback, for content this app did not pin.
 */
const PINATA_JWT = process.env.PINATA_JWT ?? "";

/**
 * A dedicated gateway (`https://<name>.mypinata.cloud`) if the account has one.
 *
 * The scheme is optional because Pinata's dashboard shows the bare hostname, and that is what gets
 * pasted. Without this, `https://` missing produces a relative URL, `fetch` throws, and the gateway
 * is skipped in silence — the one failure that looks identical to having set nothing at all.
 */
const PINATA_GATEWAY = (() => {
  const raw = (process.env.PINATA_GATEWAY ?? "").trim().replace(/\/+$/, "");
  if (!raw) return "";
  return /^https?:\/\//.test(raw) ? raw : `https://${raw}`;
})();

/** Tried after Pinata, unauthenticated, for CIDs that are not ours. */
const PUBLIC_GATEWAYS = ["https://dweb.link/ipfs", "https://ipfs.io/ipfs"];

/** Campaign posts are a sentence or two of JSON. Anything larger is not ours to relay. */
const MAX_BYTES = 512 * 1024;
const TIMEOUT = 10_000;

/// `bafy…`/`bafk…` v1 and `Qm…` v0. Validated because this value goes straight into an outbound
/// URL, and an unvalidated one turns this route into an open proxy for arbitrary hosts.
const CID_PATTERN = /^(Qm[1-9A-HJ-NP-Za-km-z]{44}|b[a-z2-7]{58,})$/;

async function tryFetch(url: string, headers?: Record<string, string>): Promise<Response | undefined> {
  const controller = new AbortController();
  const abort = setTimeout(() => controller.abort(), TIMEOUT);
  try {
    const res = await fetch(url, { headers, signal: controller.signal });
    return res.ok ? res : undefined;
  } catch {
    return undefined;
  } finally {
    clearTimeout(abort);
  }
}

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    return res.status(405).json({ error: "Method not allowed" });
  }

  const cid = typeof req.query.cid === "string" ? req.query.cid.trim() : "";
  if (!CID_PATTERN.test(cid)) {
    return res.status(400).json({ error: "Expected a CID" });
  }

  // Ordered by how likely each is to actually hold the content: our dedicated gateway, then
  // Pinata's shared one with our credential, then the public DHT-backed gateways.
  const attempts: Array<[string, Record<string, string> | undefined]> = [];
  if (PINATA_GATEWAY) attempts.push([`${PINATA_GATEWAY}/ipfs/${cid}`, undefined]);
  if (PINATA_JWT) {
    attempts.push([`https://gateway.pinata.cloud/ipfs/${cid}`, { Authorization: `Bearer ${PINATA_JWT}` }]);
  }
  for (const gateway of PUBLIC_GATEWAYS) attempts.push([`${gateway}/${cid}`, undefined]);

  for (const [url, headers] of attempts) {
    const hit = await tryFetch(url, headers);
    if (!hit) continue;

    const body = await hit.text();
    if (Buffer.byteLength(body, "utf8") > MAX_BYTES) {
      return res.status(413).json({ error: "Content too large" });
    }

    // Immutable by construction — the CID is the hash of the bytes, so this can never go stale.
    res.setHeader("Cache-Control", "public, max-age=31536000, immutable");
    res.setHeader("Content-Type", hit.headers.get("content-type") ?? "application/octet-stream");
    return res.status(200).send(body);
  }

  console.error(`ipfs/cat: ${cid} not served by any of ${attempts.length} sources`);
  return res.status(504).json({ error: "Could not fetch that content from IPFS" });
}
