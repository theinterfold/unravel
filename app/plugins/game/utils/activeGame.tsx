import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import type { Address } from "viem";
import { PUB_GAME_ADDRESS, PUB_GAME_FACTORY_ADDRESS } from "@/constants";

/// Scoped to the factory, because a lobby only exists within one deployment.
///
/// A bare key survived redeployment: the browser restored a game from the previous factory, every
/// read against it failed, and the app looked broken in a way no amount of redeploying fixed —
/// the stale value was in localStorage, not in any .env. Keying by factory means a new deployment
/// starts clean and switching back to an old one restores what you were watching.
const KEY = `unravel.activeGame.${PUB_GAME_FACTORY_ADDRESS.toLowerCase()}`;

type ActiveGame = {
  /// The game every hook reads. Never the zero address unless nothing is configured at all.
  address: Address;
  /// Switches lobby. Persisted, because a player reloading mid-round should not be dropped back to
  /// whichever game the deployment happens to name.
  select: (address: Address) => void;
  /// True when the selection came from the factory rather than the build-time default.
  chosen: boolean;
};

const Context = createContext<ActiveGame | undefined>(undefined);

/// Which lobby the app is currently looking at.
///
/// Every hook used to read `PUB_GAME_ADDRESS` directly, which hard-wired the whole app to one game
/// chosen at build time. With a factory there are many, so the address becomes state — but it is
/// deliberately state with a default: an install configured for a single game keeps working
/// untouched, and `NEXT_PUBLIC_GAME_ADDRESS` remains the answer until somebody picks another.
///
/// Held in context rather than threaded through props because it is read at the leaves — a dozen
/// hooks deep — and passing it down every call site would be a much larger change for no benefit.
export function ActiveGameProvider({ children }: { children: ReactNode }) {
  const [address, setAddress] = useState<Address>(PUB_GAME_ADDRESS);
  const [chosen, setChosen] = useState(false);

  useEffect(() => {
    try {
      // The pre-scoping key, dropped on sight. Anyone who used the app before lobbies were keyed by
      // factory still has a lobby address from an older deployment sitting here.
      window.localStorage.removeItem("unravel.activeGame");

      const stored = window.localStorage.getItem(KEY);
      if (stored && /^0x[a-fA-F0-9]{40}$/.test(stored)) {
        setAddress(stored as Address);
        setChosen(true);
      }
    } catch {
      // A browser that refuses storage still gets the configured default.
    }
  }, []);

  const select = useCallback((next: Address) => {
    setAddress(next);
    setChosen(true);
    try {
      window.localStorage.setItem(KEY, next);
    } catch {
      // Selection still applies for this session.
    }
  }, []);

  const value = useMemo(() => ({ address, select, chosen }), [address, select, chosen]);

  return <Context.Provider value={value}>{children}</Context.Provider>;
}

/// The address of the lobby currently being viewed.
///
/// Falls back to the configured game when used outside a provider, so a component rendered in
/// isolation behaves as it did before lobbies existed rather than throwing.
export function useGameAddress(): Address {
  return useContext(Context)?.address ?? PUB_GAME_ADDRESS;
}

/// The full selection, for the lobby browser.
export function useActiveGame(): ActiveGame {
  const ctx = useContext(Context);
  if (!ctx) {
    return { address: PUB_GAME_ADDRESS, select: () => {}, chosen: false };
  }
  return ctx;
}
