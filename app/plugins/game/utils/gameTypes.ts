import type { Address } from "viem";

/// Mirrors `SurvivalGame.Stage`.
export enum Stage {
  Lobby = 0,
  Playing = 1,
  Jury = 2,
  Ended = 3,
  /// The lobby never filled and was abandoned. Entry fees are refundable.
  Cancelled = 4,
}

/// The phase within a round, derived from the round's timestamps rather than stored on-chain.
export type RoundPhase = "campaign" | "ballot" | "tally" | "settled";

/// Mirrors `SurvivalGame.RoundKind`. What a round's ballot decides — and therefore what its
/// options are and who is allowed to vote.
export enum RoundKind {
  /// Everyone alive votes which team goes to council. Options are teams.
  Tribal = 0,
  /// One team votes which of its own members is eliminated. Options are members of that team.
  Council = 1,
  /// Post-merge: everyone alive votes directly to eliminate. Options are players.
  Individual = 2,
  /// The eliminated choose the winner from the finalists. Options are the finalists.
  Jury = 3,
}

export const ROUND_KIND_LABEL: Record<RoundKind, string> = {
  [RoundKind.Tribal]: "Tribal",
  [RoundKind.Council]: "Council",
  [RoundKind.Individual]: "Elimination",
  [RoundKind.Jury]: "Jury",
};

export type GameConfig = {
  campaignDuration: bigint;
  ballotDuration: bigint;
  tallyGrace: bigint;
  teamCount: number;
  /// The fewest members a team must have before the game may start. Not a cap — teams may grow to
  /// MAX_BALLOT_OPTIONS regardless.
  minMembersPerTeam: number;
  /// Players needed before anyone may start. Below the full lobby by default.
  minPlayers: number;
  /// How long a lobby may sit unfilled before anyone can cancel it and release the entry fees.
  lobbyTimeout: bigint;
  mergeAt: number;
  finalists: number;
  maxMissedCheckIns: number;
  entryFee: bigint;
};

export type Round = {
  id: number;
  kind: RoundKind;
  proposalId: bigint;
  e3Id: bigint;
  openedAt: bigint;
  ballotOpensAt: bigint;
  ballotClosesAt: bigint;
  settled: boolean;
  /// Eliminated player, or the winner in a jury round. Zero until settled.
  outcome: Address;
  /// Council rounds: the team whose member is being voted out. 0 otherwise.
  targetTeam: number;
  /// Ballot option index -> player. Empty for tribal rounds.
  candidates: Address[];
  /// Ballot option index -> team. Tribal rounds only.
  candidateTeams: number[];
  /// Who may vote. Narrower than "everyone alive" in council and jury rounds.
  voters: Address[];
};

/// Whether this round's ballot options are teams rather than players.
export function votesOnTeams(round: Round): boolean {
  return round.kind === RoundKind.Tribal;
}

/// The number of ballot options, whichever kind they are.
export function optionCount(round: Round): number {
  return votesOnTeams(round) ? round.candidateTeams.length : round.candidates.length;
}

export type GameState = {
  stage: Stage;
  config: GameConfig;
  alive: Address[];
  jurors: Address[];
  winner: Address;
  pot: bigint;
  roundCount: number;
};

/// Derives the current phase of a round from the chain clock.
///
/// The contract stores only timestamps — the phase is a view concern, and computing it here keeps
/// the UI honest about the fact that a round advances by wall clock, not by transactions.
export function roundPhase(round: Round, nowSeconds: bigint, tallyGrace: bigint): RoundPhase {
  if (round.settled) return "settled";
  if (nowSeconds < round.ballotOpensAt) return "campaign";
  if (nowSeconds < round.ballotClosesAt) return "ballot";
  if (nowSeconds < round.ballotClosesAt + tallyGrace) return "tally";
  return "tally";
}

/// The circuit's MAX_OPTIONS, mirrored from `SurvivalGame.MAX_BALLOT_OPTIONS`. The only ceiling on
/// a team, because a council ballot puts one option per member on the ballot.
export const MAX_TEAM_SIZE = 10;

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as Address;
