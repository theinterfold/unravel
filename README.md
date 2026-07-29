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

### Two things worth knowing before reading the code

**Abstention is undetectable.** Ballots are secret and mask votes make slot activity meaningless, so
the chain genuinely cannot tell who voted. Inactivity forfeits therefore key off an explicit public
`checkIn()`, not off the ballot.

**Ties are frequent at small rosters**, so they get a defined rule rather than an accident of
iteration order: the winner is drawn from the tied set using the tally itself as entropy. The counts
are fixed by the time settlement runs, so the draw is deterministic and verifiable, and unlike
`block.prevrandao` no block producer can grind it.

## Immunity is public on purpose

Immunity is optional and disabled by default. When enabled, it is a **public, attributable** vote
while the elimination stays private — so each round you must protect someone on the record while
knifing someone in secret. The gap between your two ballots is the game.

Making immunity private instead would cost a second E3 per round (it cannot share the elimination
ballot: a 10-roster would need 20 options to distinguish "protect X" from "eliminate Y", which
`MAX_OPTIONS` forbids) and would put *less* information into the game, not more.

## Status

Core contracts and tests are done. The end-to-end run against a live committee, and the frontend,
are still outstanding — see the project plan.

## Trust note

The CRISP coordination server owns `setMerkleRoot` on the E3 program, so it decides who may vote.
That is acceptable for a game, but it is not a trustless property and should not be presented as one.

## License

LGPL-3.0-only. Interfold interface files under `contracts/src/interfaces/` retain their upstream
license headers.
