import { polygon, mainnet, sepolia, holesky, arbitrum, polygonMumbai, foundry, Chain } from "@wagmi/core/chains";

const chainNames = ["mainnet", "polygon", "sepolia", "holesky", "mumbai", "arbitrum", "localhost"] as const;
export type ChainName = (typeof chainNames)[number];

export function getChain(chainName: ChainName): Chain {
  switch (chainName) {
    case "mainnet":
      return mainnet;
    case "polygon":
      return polygon;
    case "arbitrum":
      return arbitrum;
    case "sepolia":
      return sepolia;
    case "holesky":
      return holesky;
    case "mumbai":
      return polygonMumbai;
    // Anvil (chain id 31337). The game is developed against a local CRISP devnet, so the app has
    // to be able to target it — without this the UI can only ever point at a testnet.
    case "localhost":
      return foundry;
    default:
      throw new Error("Unknown chain");
  }
}
