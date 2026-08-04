import { useReadContract } from "wagmi";
import type { Address } from "viem";
import { PUB_GAME_FACTORY_ADDRESS } from "@/constants";
import { GameFactoryAbi } from "../artifacts/GameFactory";
import { useGameAddress } from "../utils/activeGame";
import { ZERO_ADDRESS } from "../utils/gameTypes";

export type Sideshows = {
  /// Public, attributable protection vote — the counterweight to the sealed ballot.
  immunity?: Address;
  /// What the eliminated do between dying and the jury vote.
  graveyard?: Address;
  /// Hidden motives: each player's secret pick for the winner.
  allegiance?: Address;
};

/// Where a lobby's three side contracts live.
///
/// Read from the factory rather than the game: only `immunitySource` is reachable from
/// `SurvivalGame`, and the other two are deliberately invisible to it — they observe the game and
/// hold their own state, so the game has no reason to know they exist.
///
/// All three are absent for a game deployed before they existed, or one deployed directly rather
/// than through the factory. Callers should treat every field as optional and hide the panel rather
/// than render a broken one.
export function useSideshows(): Sideshows {
  const game = useGameAddress();

  const { data } = useReadContract({
    address: PUB_GAME_FACTORY_ADDRESS,
    abi: GameFactoryAbi,
    functionName: "sideshowsOf",
    args: game ? [game] : undefined,
    query: { enabled: !!game && !!PUB_GAME_FACTORY_ADDRESS, staleTime: Infinity },
  });

  const tuple = data as readonly [Address, Address, Address] | undefined;
  const at = (i: 0 | 1 | 2) => {
    const value = tuple?.[i];
    return value && value !== ZERO_ADDRESS ? value : undefined;
  };

  return { immunity: at(0), graveyard: at(1), allegiance: at(2) };
}
