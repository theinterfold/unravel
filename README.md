# UNRAVEL

A social survival game whose eliminations are decided by **secret ballot**, built on Interfold's
[CRISP](https://blog.theinterfold.com/crisp-private-voting-secret-ballot-fhe-zkp-mpc/) protocol.

Up to a hundred players in teams. Each round: campaign in public, vote in private, one player goes
home. The last two face a jury of everyone they eliminated.

```
   CAMPAIGN (public)  ──▶  BALLOT (encrypted)  ──▶  TALLY (counts only)
   posts, alliances,       one credit each,         "3 for Team 2, 2 for Team 1"
   promises on record      re-votes allowed         nobody learns who cast what
```

An elimination takes **two ballots**, and both are secret:

| Round | Who votes | Options | Outcome |
| --- | --- | --- | --- |
| **Tribal** | everyone alive | the surviving teams | one team is sent to council |
| **Council** | that team, alone | that team's members | one member eliminated |

Confining the council vote to the condemned team is what makes the two stages mean something. If
everyone voted in both, the same majority would just pick the victim directly and the tribal round
would be theatre. It also doubles the E3s per elimination.

Teams dissolve once few enough survive to fit on one ballot, after which everyone votes directly.

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
  options. The on-chain CRISP program only checks `numOptions >= 2`, so exceeding the upper bound
  fails at *proving* time — the contracts therefore reject it at round-open instead.

  This is why the game has teams. Applying the bound **twice** — at most 10 teams, at most 10 members
  each — supports 100 players while every ballot stays inside it. The constraint became the
  structure rather than the ceiling.
- **Eligibility is decided by the CRISP coordination server**, not the chain. By default it is
  reconstructed from Etherscan transfer/delegation logs. `SurvivalGame` implements
  `getCensus(uint256 e3Id)` so the server reads the roster directly instead — exact, and it works
  identically on a local devnet.

## Contracts

| Contract | Role |
| --- | --- |
| `RosterToken` | Soulbound `ERC20Votes` badge, one unit per member. Deployed twice: LIFE (survivors) and JURY (the eliminated). Auto-delegates on mint; timestamp clock. |
| `SurvivalGame` | The state machine: lobby and teams, tribal/council/individual/jury rounds, tally settlement, prize pot. |
| `IImmunitySource` | Optional hook for a *public* immunity vote (see below). |
| `plugin/CrispVoting` | Vendored Aragon plugin. Creating a proposal on it requests the round's E3. Separate Foundry root — see `plugin/README.md`. |

Ballots never touch either contract: voters submit to the CRISP coordination server, which publishes
them to the CRISP program. The game only pins who may vote and on whom, then reads the tally.

## Playing it locally

One command brings up a CRISP devnet, deploys the game, funds the pot, configures the app and
serves the frontend:

```bash
bun run setup   # first time only — installs app + harness deps
bun run play
```

That deploys everything in the order the dependencies force: LIFE/JURY badges → DAO + CRISP voting
plugin → game → point the plugin's `censusProvider` back at the game. The plugin needs the LIFE
address at initialization, and the game needs the plugin's, so the order is not optional.

The DAO is deployed directly rather than through Aragon's `DAOFactory`/`PluginRepoFactory`: those are
framework contracts that only exist on public networks, and their job is publishing a versioned
plugin to a repo. Local testing needs a working plugin, not a published one.

The chain runs on **8545**, which is what MetaMask's built-in "Localhost 8545" network already
points at — so there is usually nothing to configure. Import anvil accounts **6–9**; accounts 0–5
are the CRISP server's signer and the five ciphernodes, and sharing them races nonces against
processes that transact on their own.

### Commands

| | |
| --- | --- |
| `bun run play` | full bootstrap, then serve the app |
| `bun run play:reuse` | keep the running devnet, deploy a fresh game |
| `bun run play:headless` | bootstrap only, no frontend |
| `bun run devnet:up` / `devnet:down` | start / stop the stack (down kills only this stack) |
| `bun run devnet:status` | what is running, and what phase the round is in |
| `bun run devnet:round` | drive a round headlessly against the recorded deployment |
| `bun run devnet:logs` | tail the coordination server and ciphernodes |
| `bun run contracts:build` / `contracts:test` / `contracts:fmt` | Foundry |
| `bun run contracts:abi` | regenerate the app's ABIs after a contract change |
| `bun run app:dev` / `app:build` / `app:typecheck` | frontend |
| `bun run check:encoding` | verify the ballot encoding round-trips |
| `bun run plugin:build` / `plugin:test` | vendored Aragon plugin |
| `bun run test` | contracts + plugin + encoding |
| `bun run lint` | `forge fmt --check` + app typecheck |
| `bun run deploy:sepolia:dry` | simulate a Sepolia deploy, broadcast nothing |
| `bun run deploy:sepolia` | deploy to Sepolia (needs `PRIVATE_KEY`) |

`play.sh` records every deployed address in `.devnet.env`, and the other scripts read it. That file
is the single source of truth: `devnet:round` and `devnet:status` never re-derive or redeploy, which
is what previously let them drift out of step with the deployment order.

`devnet:status` is usually the fastest way to answer "why isn't this working" — most confusing
failures are a service being down or a wallet on the wrong port, not a contract rejecting anything.

**The ballot is unavailable for the first ~5 minutes of a round.** The committee key takes ~290s to
publish and nothing can be encrypted before it exists — that is the campaign phase doing its job,
not a hang. Windows default to 900s each so there is time to drive several wallets by hand.

Two devnets cannot safely share a machine: CRISP's own `dev.sh` tears down with `pkill -f anvil`,
which matches by process name and kills every chain running. Run beside an existing devnet with
`ANVIL_PORT=8546 ./scripts/play.sh` — every other port shifts with it — but note that only
protects other stacks from this one, not the reverse.

## Sepolia

```bash
cp .env.example .env                  # fill in PRIVATE_KEY (gitignored)
bun run deploy:sepolia:dry            # simulate first
bun run deploy:sepolia
```

Anything already in your environment beats `.env`, so `RPC_URL=... bun run deploy:sepolia` still
overrides it.

Interfold, CRISP program, fee token and the hosted coordination server default to the
the-interfold-governance Sepolia values, so only a key and (optionally) an RPC are needed. Addresses
land in `.sepolia.env`.

The script claims fee tokens from the Interfold faucet and funds the pot itself — every round's E3
fee comes out of the pot, so a game with an empty pot cannot open a round at all. If the faucet
declines (it reverts once you already hold enough), it prints the manual `approve`/`fund` calls.

The Sepolia committee is three nodes on a remote server and forms faster than the local five-node
setup that produced the ~290s figure, so the campaign window defaults to 15 minutes rather than
hours. It still has to outlast sortition plus the DKG — the ballot opens the moment it ends, and a
window that is too short leaves the ballot dead for its whole duration. Worth measuring on the first
round instead of trusting the default.

### Two things worth knowing before reading the code

**Abstention is undetectable.** Ballots are secret and mask votes make slot activity meaningless, so
the chain genuinely cannot tell who voted. Inactivity forfeits therefore key off an explicit public
`checkIn()`, not off the ballot.

**Ties are frequent at these sizes**, so they get a defined rule rather than an accident of
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
