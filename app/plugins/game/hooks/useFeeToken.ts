import { erc20Abi, formatUnits } from "viem";
import { useReadContracts } from "wagmi";
import { PUB_INTERFOLD_FEE_TOKEN_ADDRESS } from "@/constants";

/// Formatting for the token the pot is denominated in.
///
/// Decimals are read from the token rather than hardcoded. The Interfold fee token is 6 decimals
/// while FOLD is 18, so assuming either one is a silent factor-of-10^12 error — and the number it
/// corrupts is the prize, which is the single figure players care most about.
///
/// Until the read lands there is no correct way to render a balance, so `format` returns `undefined`
/// rather than guessing. Showing raw base units in the meantime is what made a 200-token pot read
/// as "200000000", which looks like noise and reads as a bug.
export function useFeeToken() {
  const { data } = useReadContracts({
    contracts: [
      { address: PUB_INTERFOLD_FEE_TOKEN_ADDRESS, abi: erc20Abi, functionName: "decimals" },
      { address: PUB_INTERFOLD_FEE_TOKEN_ADDRESS, abi: erc20Abi, functionName: "symbol" },
    ],
    query: { enabled: !!PUB_INTERFOLD_FEE_TOKEN_ADDRESS, staleTime: Infinity },
  });

  const decimals = data?.[0]?.status === "success" ? (data[0].result as number) : undefined;
  const symbol = data?.[1]?.status === "success" ? (data[1].result as string) : undefined;

  /// A human amount, or undefined while the token's decimals are still unknown.
  const format = (amount: bigint | undefined): string | undefined => {
    if (amount === undefined || decimals === undefined) return undefined;
    const whole = formatUnits(amount, decimals);
    // Pots are whole-ish numbers; trailing zeros past two places are noise on a headline figure.
    const n = Number(whole);
    if (!Number.isFinite(n)) return whole;
    return n.toLocaleString(undefined, { maximumFractionDigits: 2 });
  };

  return { decimals, symbol, format };
}
