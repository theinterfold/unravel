import { PUB_IPFS_ENDPOINTS, PUB_APP_NAME } from "@/constants";
import { type Hex, fromHex, toBytes } from "viem";
import { CID } from "multiformats/cid";
import * as raw from "multiformats/codecs/raw";
import { sha256 } from "multiformats/hashes/sha2";

/// Per-gateway, not total: a slow first gateway must not eat the whole budget for the rest.
const IPFS_FETCH_TIMEOUT = 5000;
const UPLOAD_FILE_NAME = `${PUB_APP_NAME.toLowerCase().trim().replaceAll(" ", "-")}.json`;

export function fetchIpfsAsJson(ipfsUri: string) {
  return fetchRawIpfs(ipfsUri).then((res) => res.json());
}

export function fetchIpfsAsText(ipfsUri: string) {
  return fetchRawIpfs(ipfsUri).then((res) => res.text());
}

export function fetchIpfsAsBlob(ipfsUri: string) {
  return fetchRawIpfs(ipfsUri).then((res) => res.blob());
}

/**
 * Pins metadata via the server-side proxy (`/api/ipfs/pin`).
 *
 * The Pinata credential lives on the server only — see `pages/api/ipfs/pin.ts`.
 * Never call Pinata directly from the browser: a `NEXT_PUBLIC_*` token is
 * inlined into the bundle and readable by every visitor.
 */
export async function uploadToPinata(strBody: string) {
  const res = await fetch("/api/ipfs/pin", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ content: strBody, name: UPLOAD_FILE_NAME }),
  });

  const resData = (await res.json()) as { uri?: string; error?: string };

  if (!res.ok || resData.error) throw new Error(resData.error ?? "Could not pin the metadata");
  else if (!resData.uri) throw new Error("Could not pin the metadata");
  return resData.uri;
}

export async function getContentCid(strMetadata: string) {
  const bytes = raw.encode(toBytes(strMetadata));
  const hash = await sha256.digest(bytes);
  const cid = CID.create(1, raw.code, hash);
  return `ipfs://${cid.toV1().toString()}`;
}

// Internal helpers

async function fetchRawIpfs(ipfsUri: string): Promise<Response> {
  if (!ipfsUri) throw new Error("Invalid IPFS URI");
  else if (ipfsUri.startsWith("0x")) {
    // fallback
    ipfsUri = fromHex(ipfsUri as Hex, "string");

    if (!ipfsUri) throw new Error("Invalid IPFS URI");
  }

  const cid = resolvePath(ipfsUri);

  // The server-side proxy first. It is authenticated against the account that pinned the content,
  // so for anything this app posted it is the only source guaranteed to have it — the public
  // gateways have to find it on the DHT, which for a freshly pinned block often never resolves.
  const proxied = await tryOne(`/api/ipfs/cat?cid=${encodeURIComponent(cid)}`);
  if (proxied) return proxied;

  // Then the configured gateways directly, which still matter: they cover content this app did not
  // pin, and they keep working if the proxy is unavailable.
  const uriPrefixes = PUB_IPFS_ENDPOINTS.split(",").filter((uri) => !!uri.trim());

  for (const uriPrefix of uriPrefixes) {
    const hit = await tryOne(`${uriPrefix}/${cid}`);
    if (hit) return hit; // .json(), .text(), .blob(), etc.
  }

  throw new Error(
    `Could not fetch ${cid} from the pinning proxy or any of ${uriPrefixes.length} IPFS gateways`
  );
}

/// One source, with a deadline. Returns undefined rather than throwing, so a caller can move on.
///
/// The two ways a gateway actually fails — the abort firing, and a network or CORS rejection — both
/// throw rather than returning a non-ok response. Uncaught, the first dead gateway ended the loop
/// and the rest were never tried, which made a list of fallbacks behave like a single endpoint.
async function tryOne(url: string): Promise<Response | undefined> {
  const controller = new AbortController();
  const abortId = setTimeout(() => controller.abort(), IPFS_FETCH_TIMEOUT);
  try {
    const response = await fetch(url, { method: "GET", signal: controller.signal });
    return response.ok ? response : undefined;
  } catch {
    return undefined;
  } finally {
    clearTimeout(abortId);
  }
}

function resolvePath(uri: string) {
  const path = uri.includes("ipfs://") ? uri.substring(7) : uri;
  return path;
}
