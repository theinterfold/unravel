# Vendored CRISP Aragon voting plugin

Forked from [`crisp-aragon-plugin`](https://github.com/gnosisguild/crisp-aragon-plugin) — the
variant without Staged Proposal Processor staging.

## Why this is a separate Foundry root

Aragon OSx pins **OpenZeppelin 4.9.6**; `../contracts` uses **5.1.0**. They are not source
compatible for what the game uses — v5's `Ownable(address)` constructor, the `_update` hook and the
`Nonces` module either differ or do not exist in v4 — and Foundry remappings are global per project.
Keeping this as its own root means each side compiles against the version it was written for, with
no remapping tricks and no rewrite of working code.

The game only needs this plugin's **address and ABI**, never its source, so the split costs nothing.

## Local changes to the fork

1. **`E3RequestParams` drops `proofAggregationEnabled`.** Upstream carries that trailing bool; the
   Interfold built from the monorepo does not have it. The whole struct is one ABI selector, so the
   extra field silently changes `request` from `0x2215c91d` to `0xf3ceba3a` and every call reverts
   with *empty data* — no named error, nothing to diagnose from. Verified: `cast sig` on the
   six-field struct returns `0x2215c91d`.

2. **`snapshotBlock` reads the token's ERC-6372 clock**, not `block.number - 1`. `RosterToken` is
   timestamp-clocked, and asking `getPastVotes` for a block number against a timestamp clock returns
   zero voting power for everyone — a silent wrong answer rather than a revert. Ported the
   `_tokenClock()` helper from the-interfold-governance fork, which had already solved this.

## Dependencies

Pinned to the revisions the upstream fork was built against (`foundry.lock` there), because the
current `aragon/osx` main has moved its sources from `packages/contracts/src/` to `src/` and no
longer matches the remappings.

`node_modules/@aragon/token-voting-plugin` is needed only by `CrispVotingSetup.sol` — the contract
that installs the plugin into a DAO through Aragon's PluginSetupProcessor. `CrispVoting.sol` itself
does not need it.

## Build

```bash
forge build --skip 'test/**' --skip 'script/**'
```

The vendored tests and scripts are excluded for now: they pull in DAO builders and fixtures that
need more of the upstream harness than has been brought across.
