import { getChain } from "./utils/chains";

import type { Address } from "viem";
import type { ChainName } from "./utils/chains";

// Game contracts
export const PUB_GAME_ADDRESS = (process.env.NEXT_PUBLIC_GAME_ADDRESS ?? "") as Address;
export const PUB_LIFE_TOKEN_ADDRESS = (process.env.NEXT_PUBLIC_LIFE_TOKEN_ADDRESS ?? "") as Address;
export const PUB_JURY_TOKEN_ADDRESS = (process.env.NEXT_PUBLIC_JURY_TOKEN_ADDRESS ?? "") as Address;
// Paid to join, and used to settle Interfold E3 fees each round.
export const PUB_INTERFOLD_FEE_TOKEN_ADDRESS = (process.env.NEXT_PUBLIC_INTERFOLD_FEE_TOKEN_ADDRESS ?? "") as Address;

// Testnet faucet: drips the fee token to the caller.
export const PUB_FAUCET_ADDRESS = (process.env.NEXT_PUBLIC_FAUCET_ADDRESS ?? "") as Address;
// Testnet-only UI. Must be false/unset in production — there is no faucet on mainnet
// and the button would point at a non-existent contract.
export const PUB_ENABLE_FAUCET =
  (process.env.NEXT_PUBLIC_ENABLE_FAUCET ?? "").toLowerCase() === "true" && !!PUB_FAUCET_ADDRESS;

// CRISP coordination server: serves round state, the committee key, the eligibility Merkle leaves,
// and accepts encrypted ballots.
export const PUB_CRISP_SERVER_URL = (process.env.NEXT_PUBLIC_CRISP_SERVER_URL ?? "") as string;
// The CRISP E3 program contract — decodes the decrypted tally.
export const PUB_CRISP_PROGRAM_ADDRESS = (process.env.NEXT_PUBLIC_CRISP_PROGRAM_ADDRESS ?? "") as Address;
export const PUB_INTERFOLD_ADDRESS = (process.env.NEXT_PUBLIC_INTERFOLD_ADDRESS ?? "") as Address;

export const PUBLIC_SECONDS_PER_BLOCK = Number(process.env.NEXT_PUBLIC_SECONDS_PER_BLOCK ?? 1);

// Target chain
export const PUB_CHAIN_NAME = (process.env.NEXT_PUBLIC_CHAIN_NAME ?? "sepolia") as ChainName;
export const PUB_CHAIN = getChain(PUB_CHAIN_NAME);
export const PUB_CHAIN_ID = PUB_CHAIN.id;

// Network and services
export const PUB_WEB3_ENDPOINT = process.env.NEXT_PUBLIC_WEB3_ENDPOINT ?? "";
export const PUB_WALLET_CONNECT_PROJECT_ID = process.env.NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID ?? "";
export const PUB_IPFS_ENDPOINTS = process.env.NEXT_PUBLIC_IPFS_ENDPOINTS ?? "";

// Block the game was deployed at — the start of the campaign-event scan.
export const PUB_DEPLOYMENT_BLOCK = Number(process.env.NEXT_PUBLIC_GAME_DEPLOYMENT_BLOCK ?? 0);

export const PUB_APP_NAME = "UNRAVEL";
export const PUB_APP_DESCRIPTION =
  "A social survival game decided by secret ballot. Campaign in public, vote in private, one player goes home each round.";

export const PUB_PROJECT_LOGO = "/theinterfold-logo.png";
export const PUB_PROJECT_URL = process.env.NEXT_PUBLIC_PROJECT_URL ?? "https://theinterfold.com/";
export const PUB_WALLET_ICON = "https://avatars.githubusercontent.com/u/37784886";
export const PUB_BLOG_URL = "https://blog.theinterfold.com/";
export const PUB_SOCIALS_URL = "https://x.com/theinterfold";
export const PUB_CRISP_INFO_URL = process.env.NEXT_PUBLIC_CRISP_INFO_URL ?? "https://docs.theinterfold.com/";
