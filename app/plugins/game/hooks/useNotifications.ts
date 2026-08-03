import { useCallback, useEffect, useRef, useState } from "react";

type Permission = "unsupported" | "default" | "granted" | "denied";

/// Browser notifications for the moments that cost you the game if you miss them.
///
/// A round is an hour and a game is a day, so nobody watches the tab the whole time. The check-in
/// takeover only helps somebody already looking at it, and the most common death in a game like this
/// is not being outplayed but being absent.
///
/// Deliberately narrow: it fires only for things the player must *act* on, and only for things that
/// apply to them. A notification for every phase change in every lobby would be trained away within
/// one game, and then the one that mattered would go unread too.
export function useNotifications() {
  const [permission, setPermission] = useState<Permission>("unsupported");

  useEffect(() => {
    if (typeof window === "undefined" || !("Notification" in window)) return;
    setPermission(Notification.permission as Permission);
  }, []);

  const request = useCallback(async () => {
    if (typeof window === "undefined" || !("Notification" in window)) return;
    const result = await Notification.requestPermission();
    setPermission(result as Permission);
  }, []);

  const notify = useCallback(
    (title: string, body: string) => {
      if (permission !== "granted") return;
      // Not while the player is already looking: a notification for what is on screen is noise.
      if (typeof document !== "undefined" && document.visibilityState === "visible") return;
      try {
        new Notification(title, { body, tag: title });
      } catch {
        // Some browsers refuse construction outside a service worker; nothing here depends on it.
      }
    },
    [permission]
  );

  return { permission, request, notify };
}

/// Fires `notify` once each time `key` changes to a truthy value.
///
/// The phase is derived from a clock that ticks every second, so anything driven by it re-evaluates
/// constantly. Without this a single "ballot open" would fire sixty times a minute.
export function useAnnounce(key: string | undefined, announce: () => void) {
  const last = useRef<string | undefined>(undefined);

  useEffect(() => {
    if (!key || key === last.current) return;
    last.current = key;
    announce();
    // `announce` is rebuilt every render by design; the key is what decides whether to fire.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
}
