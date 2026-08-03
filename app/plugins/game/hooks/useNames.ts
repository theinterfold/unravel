import { useReadContract, useWriteContract } from "wagmi";
import type { Address } from "viem";
import { PUB_NAME_REGISTRY_ADDRESS } from "@/constants";
import { NameRegistryAbi } from "../artifacts/NameRegistry";
import { shortAddress } from "../utils/tribes";

/// Display names for a set of players.
///
/// One batched call rather than one per player: a roster of a hundred would otherwise be a hundred
/// round trips before anything renders. Returns a lookup keyed by lowercased address, and callers
/// fall back to the shortened address — a name is a convenience, never a requirement, and nothing
/// on chain reads it.
export function useNames(players: Address[], pollMs = 60_000) {
  const { data } = useReadContract({
    address: PUB_NAME_REGISTRY_ADDRESS,
    abi: NameRegistryAbi,
    functionName: "namesOf",
    args: [players],
    query: {
      enabled: !!PUB_NAME_REGISTRY_ADDRESS && players.length > 0,
      refetchInterval: pollMs,
      // Names change rarely, and the address list is already part of the query key.
      staleTime: 30_000,
    },
  });

  const names: Record<string, string> = {};
  const resolved = (data as readonly string[] | undefined) ?? [];
  players.forEach((p, i) => {
    const name = resolved[i]?.trim();
    if (name) names[p.toLowerCase()] = name;
  });

  return names;
}

/// What to call somebody: their name if they set one, their address otherwise.
export function displayName(address: string | undefined, names: Record<string, string>): string {
  if (!address) return "—";
  return names[address.toLowerCase()] ?? shortAddress(address);
}

/// Setting your own name.
export function useSetName() {
  const { writeContractAsync, isPending } = useWriteContract();

  const setName = (name: string) =>
    writeContractAsync({
      address: PUB_NAME_REGISTRY_ADDRESS,
      abi: NameRegistryAbi,
      functionName: "setName",
      args: [name],
    });

  return { setName, isPending, configured: !!PUB_NAME_REGISTRY_ADDRESS };
}
