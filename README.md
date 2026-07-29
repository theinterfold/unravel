# UNRAVEL

A social survival game whose eliminations are decided by **secret ballot**, built on Interfold's
[CRISP](https://blog.theinterfold.com/crisp-private-voting-secret-ballot-fhe-zkp-mpc/) protocol.

Ten players. Each round: campaign in public, vote in private, one player goes home. The last two
face a jury of everyone they eliminated.

```
   CAMPAIGN (public)  ──▶  BALLOT (encrypted)  ──▶  TALLY (counts only)
   posts, alliances,       one credit each,         "3 for Alice, 2 for Bob"
   promises on record      re-votes allowed         nobody learns who cast what
```

## Why secret ballots make this a game

Three CRISP properties do work that a TV production team normally has to do by hand:

| Property | Mechanic |
| --- | --- |
| Only aggregate counts decrypt | Campaign for one outcome in public, vote for another in private — unprovably. |
| Re-voting, last vote wins | A vote promised at hour 2 is worthless at hour 23. |
| Mask votes | You cannot prove which ciphertext was yours, so votes cannot be bought. |

That last one is why a naive on-chain version of this game does not work: without receipt-freeness,
a coordinated bloc simply buys the game. Coercion resistance is not a privacy garnish here — it is
what keeps the social layer load-bearing.

## Design constraints that shaped this

Both were found by reading the CRISP implementation, and both are enforced in the contracts:

- **`MAX_OPTIONS = 10`** in the Noir circuit (`circuits/lib/src/constants.nr`). At most ten ballot
  candidates. The on-chain CRISP program only checks `numOptions >= 2`, so exceeding the upper bound
  fails at *proving* time — `SurvivalGame` therefore rejects it at round-open instead.
- **Eligibility is decided by the CRISP coordination server**, not the chain. By default it is
  reconstructed from Etherscan transfer/delegation logs. `SurvivalGame` implements
  `getCensus(uint256 e3Id)` so the server reads the roster directly instead — exact, and it works
  identically on a local devnet.

## Contracts

| Contract | Role |
| --- | --- |
| `RosterToken` | Soulbound `ERC20Votes` badge, one unit per member. Deployed twice: LIFE (survivors) and JURY (the eliminated). Auto-delegates on mint; timestamp clock. |
| `SurvivalGame` | The state machine: lobby, rounds, ballots, tally settlement, jury endgame, prize pot. |
| `IImmunitySource` | Optional hook for a *public* immunity vote (see below). |

```bash
cd contracts
forge build
forge test
```

## Playing it locally

One command brings up a CRISP devnet, deploys the game, funds the pot, configures the app and
serves the frontend:

```bash
./scripts/play.sh
```

The chain runs on **8545**, which is what MetaMask's built-in "Localhost 8545" network already
points at — so there is usually nothing to configure. Import anvil accounts **6–9**; accounts 0–5
are the CRISP server's signer and the five ciphernodes, and sharing them races nonces against
processes that transact on their own.

| | |
| --- | --- |
| `./scripts/play.sh` | full bootstrap, then serve |
| `./scripts/play.sh --no-app` | bootstrap only |
| `./scripts/play.sh --reuse` | keep the running devnet, deploy a fresh game |
| `./scripts/devnet/teardown.sh` | stop this stack (and only this stack) |
| `./scripts/devnet/run-round.sh 4` | headless round, no browser |
| `node scripts/devnet/check-encoding.mjs` | verify the ballot encoding round-trips |

**The ballot is unavailable for the first ~5 minutes of a round.** The committee key takes ~290s to
publish and nothing can be encrypted before it exists — that is the campaign phase doing its job,
not a hang. Windows default to 900s each so there is time to drive several wallets by hand.

Two devnets cannot safely share a machine: CRISP's own `dev.sh` tears down with `pkill -f anvil`,
which matches by process name and kills every chain running. Run beside an existing devnet with
`ANVIL_PORT=8546 ./scripts/play.sh` — every other port shifts with it — but note that only
protects other stacks from this one, not the reverse.

### Two things worth knowing before reading the code

**Abstention is undetectable.** Ballots are secret and mask votes make slot activity meaningless, so
the chain genuinely cannot tell who voted. Inactivity forfeits therefore key off an explicit public
`checkIn()`, not off the ballot.

**Ties are frequent at small rosters**, so they get a defined rule rather than an accident of
iteration order: the winner is drawn from the tied set using the tally itself as entropy. The counts
are fixed by the time settlement runs, so the draw is deterministic and verifiable, and unlike
`block.prevrandao` no block producer can grind it.

## Immunity is public on purpose

Immunity is optional and disabled by default (`SurvivalGame.setImmunitySource`). When enabled,
`PublicImmunityVote` runs a **public, attributable** election for who cannot be eliminated, while
the elimination itself stays private. Each round you protect someone on the record and knife
someone in secret. The gap between your two ballots is the game.

A tie protects nobody — handing out immunity that no majority voted for is worse than an
indecisive round.

Two things this is deliberately *not*:

- **Not private.** A second secret ballot would cost another E3 per round and put *less*
  information into the game. It also cannot share the elimination ballot: a 10-roster would need 20
  options to distinguish "protect X" from "eliminate Y", which `MAX_OPTIONS` forbids.
- **Not an Aragon TokenVoting plugin.** TokenVoting decides Yes/No/Abstain on a proposal; immunity
  is an N-way election, which would need one proposal per candidate per round. `PublicImmunityVote`
  votes directly against the same `ERC20Votes` roster token a plugin would have used.

## Running it under a DAO

`SurvivalGame` is `Ownable`, so a DAO can hold ownership and therefore the abort/sweep/immunity
controls, and fund the pot through `fund()`. Nothing in the round loop needs the DAO to be in the
path — which is the point: the state machine stays simple and the treasury governance is separable.

## Status

| | |
| --- | --- |
| Contracts + tests | done (61 tests) |
| Ballot encoding | verified — `check-encoding.mjs`, 13 checks |
| CRISP census hook | **verified live** — the server reads `getCensus` and builds the eligibility tree from it |
| Committee forms and publishes a key | verified live, ~290s |
| Encrypted ballots accepted on-chain | verified live |
| Decrypted tally → a real elimination | **not yet observed** |

Everything up to and including `settleRound` executing on a real tally read has run against a live
devnet. What has not been seen is a round where someone is actually voted out: on the first round
that had votes to decrypt, the committee failed with `DecryptionInvalidShares` and the plaintext
never published, so the tally read back as zeros and the round correctly voided.

One lead worth checking before blaming the committee: the Rust and TypeScript tally decoders both
segment by `MAX_MSG_NON_ZERO_COEFFS / numOptions` (100/n), while `CRISPProgram.decodeTally` segments
by `tally.length / numOptions`. Those agree only if `plaintextOutput` decodes to exactly 100
`uint64`s — and `fhe_processor` returns the whole ciphertext sum, so the decrypted polynomial is
plausibly full degree. If so, the on-chain decoder reads the wrong coefficients and would return
zeros regardless of the committee. Unverified, because no run ever produced a plaintext to measure.

Timings are measured rather than guessed: the DKG floor above is from an actual round, on a machine
that was also running another proving workload. It moves with hardware, committee size and preset.

## Trust note

The CRISP coordination server owns `setMerkleRoot` on the E3 program, so it decides who may vote.
That is acceptable for a game, but it is not a trustless property and should not be presented as one.

## License

LGPL-3.0-only. Interfold interface files under `contracts/src/interfaces/` retain their upstream
license headers.
