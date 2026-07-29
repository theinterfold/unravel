import { PUB_CHAIN, PUB_WEB3_ENDPOINT } from "@/constants";
import { createPublicClient, http } from "viem";

/// Reads follow the configured chain rather than a hardcoded one, so the same build runs against a
/// local devnet and a testnet.
export const publicClient = createPublicClient({
  chain: PUB_CHAIN,
  transport: http(PUB_WEB3_ENDPOINT || undefined),
});
