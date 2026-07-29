import type { Address } from "viem";

/// Mirrors `SurvivalGame.Stage`.
export enum Stage {
  Lobby = 0,
  Playing = 1,
  Jury = 2,
  Ended = 3,
}

/// The phase within a round, derived from the round's timestamps rather than stored on-chain.
export type RoundPhase = "campaign" | "ballot" | "tally" | "settled";

export type GameConfig = {
  campaignDuration: bigint;
  ballotDuration: bigint;
  tallyGrace: bigint;
  rosterSize: number;
  finalists: number;
  maxMissedCheckIns: number;
  entryFee: bigint;
};

export type Round = {
  id: number;
  e3Id: bigint;
  openedAt: bigint;
  ballotOpensAt: bigint;
  ballotClosesAt: bigint;
  settled: boolean;
  /// Eliminated player (elimination round) or winner (jury round). Zero until settled.
  outcome: Address;
  /// Ballot option index -> player. This is the mapping a vote is cast against.
  candidates: Address[];
  /// Who may vote. Differs from `candidates` in the jury round.
  voters: Address[];
};

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

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as Address;
