import { RoundKind } from "./gameTypes";

/// The four tribes.
///
/// Teams are 1-indexed on chain and unnamed — the contract only knows `uint8 team`. Names and
/// colours live here because they are a presentation concern, and because "CINDER" is a far faster
/// read across a roster than "Team 1". The index is what the ballot is actually cast against; the
/// name is never sent anywhere.
///
/// Green is never a tribe and red is never a tribe: those two belong to the system, for
/// "your obligation is discharged" and "you are in danger" respectively. A fifth team would have to
/// be given a colour that is neither.
export const TRIBES = [
  { name: "CINDER", color: "var(--un-tribe-1)" },
  { name: "SALT", color: "var(--un-tribe-2)" },
  { name: "VERGE", color: "var(--un-tribe-3)" },
  { name: "THORN", color: "var(--un-tribe-4)" },
] as const;

/// Tribe identity for a 1-indexed team id. Team 0 means "no tribe" — either the merge has happened
/// or the player is unplaced.
export function tribe(team: number): { name: string; color: string } | undefined {
  if (team < 1) return undefined;
  const entry = TRIBES[(team - 1) % TRIBES.length];
  // Beyond the four named tribes the contract still works, so fall back to a number rather than
  // silently reusing a name — two tribes sharing a colour would break the roster's fastest read.
  return team > TRIBES.length ? { name: `TEAM ${team}`, color: entry.color } : entry;
}

/// What each round type asks of you, in one line.
///
/// Deliberately phrased as the obligation rather than the mechanic: a player glancing at a phone
/// needs to know what they are voting *on*, not how the contract models it.
export const ROUND_RULE: Record<RoundKind, string> = {
  [RoundKind.Tribal]: "Everyone votes for a TRIBE. The tribe with the most votes goes to council.",
  [RoundKind.Council]: "Only the condemned tribe votes — for one of their own. Everyone else watches.",
  [RoundKind.Individual]: "Tribes are dissolved. Everyone votes for a person.",
  [RoundKind.Jury]: "Only ELIMINATED players vote, choosing the winner from the finalists.",
};

/// The badge shown for each round type. `SOLO` rather than `ELIMINATION` because it has to fit a
/// badge and read at a glance.
export const ROUND_BADGE: Record<RoundKind, { name: string; hint: string }> = {
  [RoundKind.Tribal]: { name: "TRIBAL", hint: "pick a tribe" },
  [RoundKind.Council]: { name: "COUNCIL", hint: "three, one dies" },
  [RoundKind.Individual]: { name: "SOLO", hint: "no tribes left" },
  [RoundKind.Jury]: { name: "JURY", hint: "the dead vote" },
};

/// Shortens an address to the form used everywhere in the game.
///
/// The address is the face here — there are no avatars — so it is always rendered the same way and
/// always in mono.
export function shortAddress(address?: string): string {
  if (!address) return "—";
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

export function sameAddress(a?: string, b?: string): boolean {
  return !!a && !!b && a.toLowerCase() === b.toLowerCase();
}

/// mm:ss, or h:mm:ss past an hour. Tabular numerals are applied by the caller's class.
export function formatCountdown(seconds: bigint | number): string {
  const total = Math.max(0, Number(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const mm = String(m).padStart(2, "0");
  const ss = String(s).padStart(2, "0");
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

export function formatClock(unixSeconds: bigint): string {
  if (unixSeconds === 0n) return "—";
  return new Date(Number(unixSeconds) * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}
