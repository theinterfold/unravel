// SPDX-License-Identifier: LGPL-3.0-only
//
// Verifies that the ballot shape UNRAVEL casts encodes and decodes the way the game assumes.
//
// The contract reads `decodeTally` and eliminates the argmax, so the thing that actually has to
// hold is: encode(one credit on candidate k) then decode == a 1 in slot k and nothing else, and
// summing several encoded ballots (which is what the committee does homomorphically) decodes to
// the per-candidate counts. Getting this wrong is silent — it produces a plausible tally for the
// wrong player.

import { decodeTally, validateVote } from "@crisp-e3/sdk";

// `encodeVote` is bundled but not exported, so it is mirrored here from
// crisp-sdk/src/encoding.ts. That still tests the thing that matters: the layout contract shared
// by the SDK's encoder, the SDK's decoder, the Noir circuit and CRISPProgram.decodeTally. If this
// mirror and the SDK's decodeTally disagree, the layout is not what the game assumes.
const MAX_MSG_NON_ZERO_COEFFS = 100;

const encodeVote = (vote) => {
  const numChoices = vote.length;
  if (numChoices < 2) throw new Error("Vote must have at least two choices");

  const segmentSize = Math.floor(MAX_MSG_NON_ZERO_COEFFS / numChoices);
  const maxValue = 2 ** segmentSize - 1;
  const out = [];

  for (let choiceIdx = 0; choiceIdx < numChoices; choiceIdx++) {
    const value = vote[choiceIdx];
    if (value > maxValue) throw new Error(`choice ${choiceIdx} exceeds max ${maxValue}`);

    // Big-endian within the segment, left-padded with zeros.
    const binary = value.toString(2).split("");
    const offset = segmentSize - binary.length;
    for (let i = 0; i < segmentSize; i++) {
      out.push(i < offset ? 0 : Number.parseInt(binary[i - offset], 10));
    }
  }

  while (out.length < MAX_MSG_NON_ZERO_COEFFS) out.push(0);
  return out;
};

let failures = 0;
const check = (label, actual, expected) => {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  const ok = a === e;
  if (!ok) failures++;
  console.log(`${ok ? "  ok  " : "FAIL  "} ${label}${ok ? "" : `\n         got ${a}\n         want ${e}`}`);
};

// The tally the committee returns is the coefficient-wise sum of every encoded ballot, so summing
// encodings here reproduces exactly what `decodeTally` is handed on-chain.
const sumEncoded = (votes) =>
  votes.map(encodeVote).reduce((acc, v) => acc.map((x, i) => x + v[i]));

console.log("one credit, one candidate — every slot in a 4-option ballot");
for (let k = 0; k < 4; k++) {
  const vote = [0, 0, 0, 0];
  vote[k] = 1;
  validateVote(vote, 1n);
  check(`candidate ${k}`, decodeTally(encodeVote(vote), 4), vote);
}

console.log("\nat the MAX_OPTIONS boundary (10 candidates)");
for (const k of [0, 4, 9]) {
  const vote = Array(10).fill(0);
  vote[k] = 1;
  validateVote(vote, 1n);
  check(`candidate ${k} of 10`, decodeTally(encodeVote(vote), 10), vote);
}

console.log("\nhomomorphic sum — what settleRound actually reads");
// Three voters knife candidate 1, two knife candidate 3.
const roster = 4;
const ballots = [];
for (let i = 0; i < 3; i++) ballots.push([0, 1, 0, 0]);
for (let i = 0; i < 2; i++) ballots.push([0, 0, 0, 1]);
check("5 ballots -> counts", decodeTally(sumEncoded(ballots), roster), [0, 3, 0, 2]);

// A tie is the case the contract has a dedicated rule for; the tally must actually report it.
check(
  "tied ballots -> equal counts",
  decodeTally(sumEncoded([[1, 0, 0, 0], [0, 1, 0, 0]]), roster),
  [1, 1, 0, 0]
);

console.log("\nabstention");
const abstain = [0, 0, 0, 0];
validateVote(abstain, 1n);
check("all-zero ballot decodes to zeros", decodeTally(encodeVote(abstain), 4), abstain);

console.log("\nrejections the circuit relies on");
const rejects = (label, fn) => {
  try {
    fn();
    failures++;
    console.log(`FAIL  ${label} — was accepted`);
  } catch {
    console.log(`  ok  ${label}`);
  }
};
rejects("splitting one credit across two candidates", () => validateVote([1, 1, 0, 0], 1n));
rejects("voting more credits than held", () => validateVote([2, 0, 0, 0], 1n));

console.log(failures === 0 ? "\nALL CHECKS PASSED" : `\n${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
