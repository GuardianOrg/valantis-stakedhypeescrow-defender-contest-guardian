# StakedHypeEscrow Defender Contest

This repository contains the review package for the StakedHypeEscrow bounty contest on Guardian Defender.

## Scope

**Only `src/StakedHypeEscrow.sol` is in scope.**

The scoped contract and supporting source files are preserved from source commit `c497da28755fd4c9c62a4350e2541ecce9f368b9`. The contest description pins this repository's prepared snapshot commit.

Everything else is supporting context and is outside the contest scope:

- `src/StakedHypeEscrowLens.sol` and `src/interfaces/*`.
- Overseer, stHYPE, wstHYPE, Ownership, tStorage and libraries required by the local tests.
- `lib/*`: pinned build and testing dependencies.
- `test/*`: the escrow-specific integration and invariant tests.
- `script/StakedHypeEscrowDeploy.s.sol`: retained because the local deployment tests import it. It is not in scope.
- `STAKED_HYPE_ESCROW_SPEC.md`: supporting protocol documentation.

The presence of a file in this repository does not make it eligible for contest findings.

## Build and test

Install Foundry, then clone this repository with its pinned submodules:

```sh
git clone --recurse-submodules https://github.com/GuardianOrg/valantis-stakedhypeescrow-defender-contest-guardian.git
cd valantis-stakedhypeescrow-defender-contest-guardian
forge build
forge test
```

If you cloned without submodules, run `git submodule update --init --recursive` first. Solidity `0.8.28` and the dependency revisions are pinned in the repository.

For a shorter local run:

```sh
FOUNDRY_INVARIANT_RUNS=32 FOUNDRY_INVARIANT_DEPTH=32 forge test --fuzz-runs 256
```

The retained tests use local fixtures. The deployment script is included for those tests; running a live deployment is not required for this contest.

## Excluded components and behavior

Findings against the following are outside the contest scope, whether or not the corresponding files are included as context:

- Overseer roles, rebase logic, the burn–redeem queue and slash accounting.
- stHYPE / wstHYPE token, wrapper and votes checkpoint behavior.
- Staking modules, including HyperCoreStakingModule, StakingModuleExternalManagement and StakingModuleExternalAccount (SMEA).
- Ownership, tStorage and library implementations.
- Third-party dependencies.
- Deployment and operational scripts.
- Off-chain keepers, HyperCore / StakeAccountManager backend and validator operations.

Examples include mint / burn / rebase timing on Overseer or stHYPE; module transit or slash-cap freezes; SMEA checkpoint behavior or the absence of an automatic write-down on managed loss; and the production shares permanently locked at `address(1)`.

## Known issues

The following known behaviors and limitations are not eligible for rewards:

- **Empty or near-empty pool:** the protocol keeps a permanent 1,000-unit seed at `address(1)` that cannot be withdrawn. When only that seed remains, donations and premiums go to an undistributed reserve, rather than to the seed or the next depositor. Operations maintains a large wstHYPE buffer so the pool is not left at dust.
- **Rounding:** amounts round down. Dust below 1 wstHYPE wei may require a top-up, and cancellation can fail if re-entry rounds to zero.
- **Bootstrap:** the first deposit can be front-run if deployment and the first deposit are not atomic.
- **Pause behavior:** `fundRewards` and `checkpoint` remain callable while user actions are paused.
- **Funding:** starting a reward stream requires fresh HYPE. The retained reserve alone cannot start one.
- **Inherited limitations:** Overseer burn caps, wrapper overflow on execution and tiny slash dust socialized upstream.

The contest page on Guardian Defender contains the complete eligibility and submission rules.
