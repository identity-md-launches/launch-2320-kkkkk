# Review and verification

This is an implementation self-review, not an independent audit. No deployment or broadcast was performed. The pinned security/address references were used as checklists; the repository contains no keys or provider credentials.

## Findings and disposition

| Finding | Disposition and evidence |
|---|---|
| Optimized tests can reinterpret a saved `block.number` or `block.timestamp` after a cheatcode changes it. This reproduced the previous attempt's zero-length checkpoint-history failure. | Fixed tests to snapshot through `vm.getBlockNumber()` / `vm.getBlockTimestamp()`. Token history keeps strict completed-block semantics. The verifier's exact fuzz seed is included in validation. |
| One-shot `prank` can be consumed by a nested getter instead of the intended creator action. | Actor-sensitive tests cache inputs or use scoped `startPrank`/`stopPrank`. Explicit tests cover transferring the creator, changing a module for future pools, cancelling and applying raises, and old-creator claims. |
| A buy fee charged on requested input would overcharge a partially executed buy. | `afterSwap` validates actual core quote input against the post-fee input captured in `beforeSwap`. Partial buys revert with all credits and transfers rolled back. Sells charge actual output. |
| Re-querying a future module after the swap can produce a different base rate, including because fee accrual itself changed the module's view inputs. | Buy execution snapshots the expected net input. A dedicated accrual-sensitive module regression demonstrates consistent settlement even when a second rate query would differ. |
| Role changes must not transfer old fee entitlements. | Creator credits are keyed by token and beneficiary; team credits by quote and beneficiary. Role transfer and takeover change future accrual only. Tests prove old/new creditors can claim independently. |
| Generic ERC20 introspection cannot establish absence of tax, future rebases or issuer upgrades. | Explicit owner attestation/allowlist and supported-decimal checks; exact receipt and payout balance checks; claims fail closed when custody is deficient. Tests exercise taxed receipt, taxed payout, false-returning transfers and an artificial negative rebase. A known rebasing/taxed quote must not be admitted. This external-token trust limit remains documented. |
| Disabling a broken quote should not depend on its metadata still responding. | Disabled quotes use previously recorded decimals and do not call the token. A reverting `decimals()` regression covers this path. |
| “ERC20 clone” conflicts with the blanket prohibition on delegatecall. | Full-code token instances preserve identical behavior without any proxy or delegatecall. Extra creation gas is documented. |
| Integer liquidity cannot consume an arbitrary exact token supply. | The whole supply is transferred to PoolManager. The quantization remainder is irrevocably cleared, and principal/dust are separately emitted and recorded. Factory position ownership and the absence of a removal path lock liquidity. |
| Quote fees may be taken before a conventional router settles input. | Test routing settles upfront. Production routing must do the same or rely on sufficient existing PoolManager quote inventory. The README explicitly records this integration requirement. |

## Part 2a findings and disposition

| Finding | Disposition and evidence |
|---|---|
| An eager 70/30 split over up to 16 quotes at round end would cost 16 × ~30k gas and could never fit the 120k `onBuy` budget. | Pots are split lazily from per-quote funding anchors; ending a round writes two slots. `onBuy` is measured on every path (≤ 119,766 gas with a 400-checkpoint winner) and asserted ≤ 120,000. The conservation `liability = potOf + Σ unpaid prizes` is an invariant. |
| A heart that reverts, burns gas or is slow must not affect swaps. | `onBuy` runs under a fixed 200k stipend inside `try/catch`; `minBuy` is also wrapped. Tests cover a reverting heart (mocked revert), a gas-burning heart and a reverting heart on fresh deployments, asserting the swap succeeds, the pulse updates and the burn costs at most the stipend. A fuzz test replays identical sequences with and without a heart on a state snapshot and compares every delta. |
| Buyer identity could be spoofed through hook data. | The hook accepts a buyer only when PoolManager's `sender` is the set-once `factory.router()` and the payload is exactly 32 bytes. Tests cover a non-router with a 32-byte payload, the router with 20-byte and 64-byte payloads and empty data. |
| The ending block must not be gameable. | `KeelV2Token.balanceAt` still rejects the current block, and the heart checks `block.number − 1`. Tests cover: holding, selling one unit, selling and buying back before the end, receiving by transfer, moving tokens in and out inside the `end()` block, and `end()` called 200,000 blocks late. |
| Permit replay and malleability. | Per-creator nonce increments on use; the signature must be 65 bytes, low-`s`, `v ∈ {27,28}`, and recover to the current signer. Tests cover replay, changed creator/quote/tick/deadline, wrong signer, empty signature, flipped `v`, expiry at the boundary, chain-id change and signer replacement. |
| Launch fee custody. | `msg.value` must equal `launchFee` exactly and is forwarded to `teamRecipient` in the same call after all state changes under the factory's reentrancy lock; failure reverts the launch and the nonce. The factory never holds ETH (asserted). |
| `FixedRateModule` refactor. | Behaviour is identical; it now inherits `RateModuleBase`. All part 1 rule tests pass unchanged apart from the error namespace. |
| Timer and bookkeeping are packed into two slots (`Live`, `LastBuy`). | `uint40 deadline`, `uint24 round` and `uint24 eligibleRounds` (≥ 300 s per round gives > 150 years), `uint96 lastTokens` (supply is 1e27 < 2^96; larger values saturate). `uint224` pot amounts; funding beyond that reverts. |
| Pulse arithmetic. | `PulseMath.decay` is fuzzed over the full `uint128 × uint256` domain for no-revert, monotonicity and exact shifts on whole half-lives; saturation at `uint128.max` is tested by storage injection. |

Part 2a remaining limits: the holding check costs about 2.1k gas per doubling of the winner's checkpoint history, so an extreme history (more than ~2^38 checkpoints) would exhaust the 200k stipend and the round would only end through `end()`. The heart trusts `KeelV2Token.balanceAt`, which only factory-created tokens provide; the hook only registers such tokens. Lazy pot settlement means `prizeOf`/`potOf` walk at most ~150 eligible rounds (the pot rounds to zero after that) per anchor. A quote added to the heart after rounds have run has a zero pot for earlier rounds. The owner's only powers are thresholds and the quote list; a wrong `minBuy` can only make buys not count.

## Static-analysis dispositions

The high-severity-only Slither run finished with **0 results** after the following changes, without detector suppression or path exclusions:

- Replaced v4 BitMath's intentional variable-shift lookup tables with constant-shift binary search; replaced FullMath's intentional XOR inverse seed with a simple modulo-2 seed and two additional precision lifts. See `lib/VENDORED.md` and `test/Math.t.sol` for provenance, proofs of intent and full-width arithmetic/boundary tests. These preserve results and remove ambiguous idioms from the verifier's high-severity scan.
- Moved exact payout-balance comparisons into the hook's guarded claim path, leaving the shared transfer helper responsible only for checked transfer execution. Both claim entry points hold the same reentrancy lock across pre-transfer and post-transfer measurements. The library's isolated balance comparison was previously reported without that calling context.
- Wrote checkpoints directly through the mapping instead of a local storage alias, making their initialization visible to the analyzer.

The medium-inclusive run reported **34 medium findings**, grouped below. It intentionally exits nonzero for these reports; there were no high findings.

| Detector / locations | Disposition |
|---|---|
| `divide-before-multiply`: v4 CustomRevert, FullMath and TickMath (13 reports) | Intentional ABI word alignment, exact removal of powers of two before modular inversion, and tick-grid rounding/fixed-point arithmetic. FullMath identities and bit boundaries are fuzz tested; v4 integration covers tick math. Reordering these expressions would change their intended arithmetic. |
| `incorrect-equality`: FixedRateModule's two zero-rate sentinels and token checkpoint block equality (3) | Zero denotes an uninitialized pool and cannot be a valid base rate. Checkpoint block equality intentionally coalesces changes within the same block. Neither equality gates a balance-dependent payout or relies on an exact timestamp. |
| `reentrancy-no-eth`: four module rate actions (4) | Their only external call is the immutable hook's `creatorAction`, which authenticates module/creator, stores a timestamp and emits an event. It makes no further external call. The hook is not upgradeable. Failed rate validation rolls back that timestamp update. |
| `reentrancy-no-eth`: factory `unlockCallback` (1) | Only immutable PoolManager can call it. It consumes `_unlocking` before the manager call, while outer `launch` holds the factory reentrancy lock. No second callback or nested launch is available; subsequent writes record measured principal/dust. The fixed callback is the necessary v4 settlement path. |
| `uninitialized-local`: token binary-search lower bound and v4 Hooks' default hook delta (2) | Solidity initializes both to zero. Zero is the intended binary-search bound and no-hook delta. Neither can carry a prior transaction's value. |
| `unused-return`: v4 callback dispatch and factory initialization/unlock/liquidity/settlement (11) | v4 `callHook` internally validates success and the response selector. Factory uses the signed principal delta, while the other outputs are descriptive: the initialized tick is already determined, the callback returns empty bytes, a brand-new zero-LP-fee position has no earned fees, and v4 enforces zero outstanding settlement at unlock completion. The fixed token transfers the exact supply; no arbitrary quote token is used in factory settlement. |

## Scope reviewed

- Token supply, allowance accounting, self-transfers, zero transfers and binary-search checkpoints.
- Exact-input quote-side fee deltas, int128 bounds, upward total rounding and downward creator-share rounding.
- Fixed launch schedule, base-rate lower/raise limits and 24-hour application boundary.
- Hook callback authentication and permission mask; pool registration and immutable module binding.
- Factory position ownership, single-sided range inversion and supply settlement.
- Two-step governance, new-launch-only configuration, once-only takeover and strict 30-day inactivity check.
- Fee-credit ownership, failed-recipient rollback, cross-claim reentrancy and liability conservation.
- Deployment script chain guard, explicit owner, bounded CREATE2 salt mining and atomic wiring.

## Remaining operational limits

The owner is trusted to admit standard quotes and audited immutable modules. External quote issuers and Uniswap governance remain outside Keel's control. There is no emergency sweep, freeze, pool-module replacement, LP recovery, or repair mechanism for a malicious module or insolvent rebasing quote. These are deliberate consequences of the requested immutability. Timestamp-based deadlines are subject to ordinary block timestamp precision; no randomness or spot-price oracle is used.

The takeover contract, production router/frontend, final quote allowlist and bounds, and actual owner/team deployment addresses are operator decisions for the later release. The supplied dry run leaves takeover unset and quote allowlisting empty. An independent review is still required before using real funds.

## Validation results (part 2a)

Completed on 2026-10-21 with the pinned Solidity 0.8.26 configuration, offline, with the verifier's fuzz seed `0x32f35d2cad9bfd8f60ebb888f94a34d8b3199251ef9873d5ed13d3f0e8890a26`:

| Check | Result |
|---|---|
| `forge build --offline` | Passed. Runtime sizes: factory 14,638, hook 11,641, heart 6,005, token 2,153, FixedRateModule 1,670, PulseRateModule 1,979 bytes. |
| `forge test --offline --fuzz-seed 0x32f3…0a26` | **107 passed, 0 failed, 1 explicit mainnet-only skip** across 18 suites. `FeeInvariantTest` and `HeartInvariantTest` each ran 128 sequences / 4,096 calls with 0 reverts. |
| `forge fmt --check` | Passed. |
| `forge snapshot --match-contract GasWith` | Recorded in `.gas-snapshot` and the README gas section. |
| Slither / Mythril / mainnet fork | Not run in this part (no network in this run; the fork suite is opt-in as before). |

## Validation results (part 1)

Completed on 2026-10-20 with the pinned Solidity 0.8.26 configuration:

| Check | Result |
|---|---|
| `forge build --offline` | Passed. |
| `forge test --offline --fuzz-seed 0x499dc327679faaf06b10ce7dcdb5c0fc53193f29b8cff9db2d228fc1e11100fb` | 55 passed, 0 failed, 1 explicitly skipped mainnet-only test. Five fuzz functions run 256 cases each; invariant handler runs 128 sequences / 4,096 calls, with 0 reverts. |
| Full mainnet fork at block **22,000,000**, same required seed | **56 passed, 0 failed, 0 skipped**. Includes actual mainnet PoolManager, real USDC swaps/claims, ETH launches/swaps, deployment dry run and stateful invariants. |
| `forge test --offline --fuzz-seed 0x5eec0de20261020 --fuzz-runs 1024` | 55 passed, 0 failed, 1 mainnet-only skip. Each of the five fuzz functions ran 1,024 cases. Invariant handler again completed 4,096 calls with 0 reverts. |
| `forge fmt --check` | Passed. |
| `forge build --sizes` | Passed for all deployable contracts; the deployment simulation is marked as a standard forge-std `Script`, not a chain contract. Sizes below. |
| Slither high-severity gate | **0 results**, including a fresh compilation of the clean export. No detector suppressions or path filters. |
| Slither medium-inclusive review | 34 medium reports; all grouped and justified above. |
| Fresh source-only export | Copied only `src/`, `test/` excluding scratch, `script/`, vendored `lib/`, root configuration and documentation into an empty directory. From there, offline build, seeded offline tests, formatting and high-severity Slither all exited 0. No existing build artifacts, caches, pinned inputs or scratch files were copied. Git metadata was not modified. |

| Contract | Runtime bytes | Initcode bytes |
|---|---:|---:|
| KeelV2Token | 2,153 | 3,465 |
| KeelV2Hook | 9,374 | 10,086 |
| KeelV2Factory | 12,400 | 12,790 |
| FixedRateModule | 1,615 | 1,776 |
| Vendored PoolManager (offline tests only) | 17,065 | 17,250 |

All deployable runtime sizes are below 24,576 bytes and initcode sizes below 49,152 bytes. The deployment script contains embedded creation code and is only a Foundry simulation script. It is not intended for on-chain deployment. Mainnet-fork verification is read-only simulation; no transaction was broadcast. Mythril and an independent human audit were not performed.
