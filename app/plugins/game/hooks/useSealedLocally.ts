import { useCallback, useEffect, useState } from "react";

const KEY = "unravel.sealed";

/// Whether *this browser* has sealed a ballot for a given E3.
///
/// This is deliberately local and deliberately weak. The chain cannot tell anyone — including the
/// player — whether a particular address voted: that is the entire point of the sealed ballot, and
/// mask votes mean even slot activity says nothing. So the only honest source for "have I voted
/// yet?" is the client that did it.
///
/// The consequence, which the UI must not paper over: vote from another device or clear this
/// storage and the app will say you still owe a ballot when you do not. That is the correct failure
/// direction — nagging someone who has already voted is recoverable, while telling someone they have
/// voted when the app cannot know is how a player loses a round.
export function useSealedLocally(e3Id: bigint | undefined) {
  const [sealed, setSealed] = useState(false);

  useEffect(() => {
    if (e3Id === undefined) return;
    try {
      const raw = window.localStorage.getItem(KEY);
      const seen: string[] = raw ? JSON.parse(raw) : [];
      setSealed(seen.includes(e3Id.toString()));
    } catch {
      setSealed(false);
    }
  }, [e3Id]);

  const markSealed = useCallback(() => {
    if (e3Id === undefined) return;
    try {
      const raw = window.localStorage.getItem(KEY);
      const seen: string[] = raw ? JSON.parse(raw) : [];
      if (!seen.includes(e3Id.toString())) {
        // Bounded: a long-running game should not grow this without limit.
        window.localStorage.setItem(KEY, JSON.stringify([...seen, e3Id.toString()].slice(-50)));
      }
      setSealed(true);
    } catch {
      setSealed(true);
    }
  }, [e3Id]);

  return { sealed, markSealed };
}
