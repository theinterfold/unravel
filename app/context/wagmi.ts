import { http, createConfig } from "wagmi";
import { injected } from "wagmi/connectors";
import { PUB_CHAIN, PUB_WEB3_ENDPOINT } from "@/constants";

/// Browser-extension wallets only (MetaMask and friends).
///
/// WalletConnect was removed deliberately. It required a project id from a third-party service
/// just to boot — without one Web3Modal throws `projectId is undefined` and the app does not
/// render at all — and its value is connecting mobile wallets to a remote dapp. This game is
/// played against a local devnet, where the wallet is in the same browser.
export const config = createConfig({
  chains: [PUB_CHAIN],
  ssr: true,
  transports: {
    [PUB_CHAIN.id]: http(PUB_WEB3_ENDPOINT, { batch: true }),
  },
  connectors: [injected()],
});
