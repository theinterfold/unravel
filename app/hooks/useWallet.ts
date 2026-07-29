import { useAccount, useConnect, useDisconnect } from "wagmi";
import { injected } from "wagmi/connectors";

/// Connect/disconnect against a browser-extension wallet.
///
/// Replaces Web3Modal's `open()`. With a single connector there is no wallet to choose between, so
/// a modal would just be an extra click in front of MetaMask's own prompt.
export function useWallet() {
  const { address, isConnected } = useAccount();
  const { connect, isPending, error } = useConnect();
  const { disconnect } = useDisconnect();

  return {
    address,
    isConnected,
    isPending,
    error,
    connect: () => connect({ connector: injected() }),
    disconnect,
    /// Connect when disconnected, disconnect when connected — for a single button.
    toggle: () => (isConnected ? disconnect() : connect({ connector: injected() })),
  };
}
