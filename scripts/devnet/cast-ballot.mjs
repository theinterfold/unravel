// SPDX-License-Identifier: LGPL-3.0-only
//
// Casts a single encrypted elimination ballot from the command line.
//
// The browser app does this through wagmi; on a devnet we need it headless so a whole round can be
// driven from a script. The CRISP SDK falls back to main-thread proving when `Worker` is undefined,
// so it runs unmodified under Node.
//
// Usage:
//   node cast-ballot.mjs --e3 <id> --key <privkey> --candidate <index> [--server <url>] [--mask]

import { hashMessage } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { CrispSDK, encodeSolidityProof, CreditMode } from "@crisp-e3/sdk";

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1) return fallback;
  return process.argv[i + 1];
}

const e3Id = Number(arg("e3", ""));
const privateKey = arg("key", "");
const candidateIndex = Number(arg("candidate", "0"));
const serverUrl = arg("server", "http://127.0.0.1:4000");
const isMask = process.argv.includes("--mask");

if (!Number.isInteger(e3Id) || !privateKey) {
  console.error("usage: cast-ballot.mjs --e3 <id> --key <privkey> --candidate <index> [--mask]");
  process.exit(2);
}

const sdk = new CrispSDK(serverUrl);
const account = privateKeyToAccount(privateKey);

const round = await sdk.getRoundStateLite(e3Id);
const publicKey = new Uint8Array(round.committee_public_key);

if (publicKey.length === 0) {
  console.error(`e3 ${e3Id}: committee key not published yet (status=${round.status})`);
  process.exit(1);
}

const numOptions = Number.parseInt(round.num_options, 10);

// The game always requests CONSTANT credits, so every voter's "balance" in the proof is the round's
// flat credit. Anything else means the round was requested wrong, and a wrong balance would produce
// a proof that fails against the eligibility tree rather than an obviously bad vote.
if (Number(round.credit_mode) !== CreditMode.CONSTANT) {
  console.error(`e3 ${e3Id}: expected CONSTANT credits, got credit_mode=${round.credit_mode}`);
  process.exit(1);
}
const balance = BigInt(round.credits);

const leaves = (await sdk.getTokenHolderHashes(e3Id)).map((h) =>
  BigInt(h.startsWith("0x") ? h : `0x${h}`)
);

console.error(
  `e3 ${e3Id}: ${numOptions} options, ${leaves.length} eligible, credits=${balance}, voter=${account.address}`
);

let proof;

if (isMask) {
  const eligible = await sdk.getEligibleAddresses(e3Id);
  const slot = eligible[Math.floor(Math.random() * eligible.length)];

  proof = await sdk.generateMaskVoteProof({
    e3Id,
    merkleLeaves: leaves,
    slotAddress: slot.address,
    publicKey,
    balance: BigInt(slot.balance),
    numOptions,
  });
} else {
  if (candidateIndex < 0 || candidateIndex >= numOptions) {
    console.error(`candidate ${candidateIndex} outside 0..${numOptions - 1}`);
    process.exit(2);
  }

  const message = `Vote for round ${e3Id}`;
  const signature = await account.signMessage({ message });

  // One credit on exactly one candidate — the only shape a valid one-credit ballot can take.
  const vote = Array.from({ length: numOptions }, (_, i) => (i === candidateIndex ? Number(balance) : 0));

  proof = await sdk.generateVoteProof({
    merkleLeaves: leaves,
    publicKey,
    balance,
    vote,
    signature,
    messageHash: hashMessage(message),
    e3Id,
    slotAddress: account.address,
  });
}

const response = await fetch(`${serverUrl}/voting/broadcast`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    encoded_proof: encodeSolidityProof(proof),
    address: account.address,
    round_id: e3Id,
  }),
});

const body = await response.text();
if (!response.ok) {
  console.error(`broadcast failed (${response.status}): ${body}`);
  process.exit(1);
}

console.log(body);
