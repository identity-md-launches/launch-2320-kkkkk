# Keel v2 — contracts, parts 1 and 2a

Keel creates immutable Uniswap v4 pools with a fixed-supply token, permanently locked liquidity and quote-denominated launch fees. This deliverable contains contracts, a simulation-only deployment script and tests. It does not deploy or broadcast transactions. Example launch metadata uses **kkkkk / lllll**.

## Build and verification

Solidity **0.8.26**, Cancun, optimizer 200 runs, IR compilation, no metadata appended to bytecode. All imported dependencies are vendored as ordinary source files. No network, environment variables, FFI or file access is required by the default tests.

```sh
forge build --offline
forge test --offline --fuzz-seed 0x499dc327679faaf06b10ce7dcdb5c0fc53193f29b8cff9db2d228fc1e11100fb
forge fmt --check
forge build --sizes
slither . --exclude-informational --exclude-optimization --exclude-low --exclude-medium
```

The default suite deploys the vendored Uniswap PoolManager, with the two arithmetic compatibility changes documented in [lib/VENDORED.md](lib/VENDORED.md), rather than a mock pool. `MainnetForkTest` is explicitly skipped without a fork. Supply a fork on the command line to run the entire suite against mainnet PoolManager, including an additional real USDC test:

```sh
forge test --fork-url https://eth.llamarpc.com --fork-block-number 22000000 \
  --fuzz-seed 0x499dc327679faaf06b10ce7dcdb5c0fc53193f29b8cff9db2d228fc1e11100fb
```

The archive endpoint must serve block 22,000,000. Mainnet PoolManager is `0x000000000004444c5dc75cB358380D2e3dE08A90`; USDC is `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`. These came from the pinned address reference; PoolManager code and USDC's symbol were checked through the supplied mainnet RPC service. The test suite chooses deployed PoolManager only when code is present at that address. It does not silently create a network fork or read a key.

Tests cover checkpoint history (including zero iterations and multiple changes in one block), ERC20 behavior, liquidity custody, launch validation, both price orientations, fees in four quote configurations, rounding, launch timing, rate changes, old/new creator credits, team handover, callback authorization, claims to contracts, reentrancy, exact-output rejection, partial-buy rejection, ownership and deployment wiring. Stateful invariant handlers mix trading, claims, role changes, rate reductions and time advancement. Block/time snapshots in tests use `vm.getBlockNumber()` and `vm.getBlockTimestamp()` so optimizer assumptions about a transaction's block do not invalidate cheatcode-driven tests.

The final validation passed **55 offline checks** (plus one explicit fork-only skip) and **56 mainnet-fork checks**, with no failures. The required fuzz seed and a second seed at 1,024 runs both passed. A clean source-only export also passed offline build/tests/format and Slither with zero high-severity results. Exact commands, contract sizes and medium-report dispositions are in [REVIEW.md](REVIEW.md).

## Part 2a: heart, pulse fees, launch permit and launch fee

Part 2a continues part 1 in place: nothing is deployed, so `KeelV2Factory`, `KeelV2Hook` and the test router were changed directly. Everything stays immutable: no proxies, no upgrade paths, no sweep or rescue functions, no admin power over funds already credited. Validation with the verifier seed: **107 offline tests passed, 0 failed, 1 explicit mainnet-only skip** (two invariant suites at 128 runs × 32 depth each), `forge fmt --check` clean, all runtime sizes below 24,576 bytes (factory 14,638, hook 11,641, heart 6,005, PulseRateModule 1,979).

### What changed in part 1 code

- `KeelV2Factory.launch` is now `payable` and takes `(name, symbol, metadata, quote, startTick, baseFeeBps, deadline, signature)`. It requires `msg.value == launchFee`, a live signer, `block.timestamp <= deadline` and a valid EIP-712 permit; the per-quote tick bounds, rate and metadata checks are unchanged. The fee is forwarded to `teamRecipient` at the end of the same call and the launch reverts (`FeeTransferFailed`) if that transfer fails.
- `KeelV2Hook.afterSwap` now reads the swap `sender`, keeps the gross buy input next to the net input it already snapshotted, updates the pool's pulse and notifies the heart. `hookData` is still forwarded to the module unchanged.
- `FixedRateModule` keeps its exact behaviour but inherits the creator controls from the new abstract `RateModuleBase`, which `PulseRateModule` also uses. Its custom errors are therefore declared on `RateModuleBase`.
- `QuoteTransfer` gained `pull` (checked `transferFrom`) for heart funding.

### Launch permit and fee (factory)

| Item | Value |
|---|---|
| EIP-712 domain | name `Keel`, version `2`, `chainId`, `verifyingContract` = factory. `DOMAIN_SEPARATOR()` is recomputed per call, so a chain fork invalidates old permits. |
| Typed data | `Launch(address creator,address quote,int24 startTick,uint256 deadline,uint256 nonce)`; `creator = msg.sender`, `nonce = nonces(creator)`, which increments on use. `launchDigest(creator, quote, startTick, deadline, nonce)` returns the digest to sign. |
| Signature | 65 bytes `r ‖ s ‖ v`, `v ∈ {27, 28}`, low-`s` only, recovered address must equal `signer()`. Malleated or replayed signatures revert `InvalidSignature`; late ones revert `PermitExpired`. |
| `signer()` | Owner-set via `setSigner(address)`, replaceable, nonzero, unset after deployment. Launches revert `NotConfigured` until it is set. Replacing the signer invalidates every unused permit. |
| `launchFee()` | Default `0.0001 ether`; `setLaunchFee(uint256)` up to `MAX_LAUNCH_FEE = 0.01 ether`. `msg.value` must equal it exactly (`WrongFee`), including zero when the fee is zero. The factory never holds ETH. |
| `router()` / `heart()` | `setRouter(address)` and `setHeart(address)`: owner, once, nonzero, must have code, cannot be changed or cleared (same pattern as `setTakeoverContract`). |

The off-chain signer picks `startTick` so that every token starts at a $5,000 market cap; the contract only checks that the tick is a multiple of 60 inside the quote's configured bounds. The tick is part of the signed message, so a creator cannot substitute another one.

### Buyer identity and heart notification (hook)

A buy is *counted* for the heart only when the swap `sender` seen by PoolManager equals `factory.router()` and `hookData` is exactly 32 bytes; `buyer = abi.decode(hookData, (address))`. Any other caller, or the router with other hook data, trades normally and gets no heart credit. A spoofed 32-byte payload from another router is ignored because the sender check fails. After a counted buy whose gross quote input is at least `heart.minBuy(quote)`, the hook calls `heart.onBuy(token, quote, buyer, grossQuoteIn, tokensOut)` with a fixed `HEART_GAS = 200_000` stipend inside `try/catch`. A reverting or gas-burning heart never reverts or changes the swap; the hook emits `HeartCallFailed(poolId)` instead. `tokensOut` is the token amount PoolManager delivered for that swap. A reverting `minBuy` is treated the same way (event, no pulse, no credit). The property "swap deltas are identical with and without a heart" is fuzz-tested by replaying the same sequence on a state snapshot with the heart masked out.

### Pulse (hook)

Each pool keeps `pulse` (uint128, `1e18` = one buy) and `pulseUpdatedAt`. On every buy with gross input ≥ `heart.minBuy(quote)` (every buy while no heart is set, and every buy of a quote whose threshold is zero), `pulse = pulse · 2^(−elapsed / 1 h) + 1e18`, saturating at `uint128.max`. `pulseOf(poolId)` returns the decayed value now; `pulseInfo(poolId)` returns the raw pair. `PulseMath.decay` caps elapsed at 64 half-lives (then zero), uses a 16-bit fraction of a half-life with sixteen Q64 constants (relative error below 2·10⁻⁵), and cannot overflow or revert for any `uint128` value and any `uint256` elapsed time. Whole half-lives are exact right shifts. The anti-snipe decay from part 1 is unchanged and independent of the pulse.

### PulseRateModule

`feeBps(poolId) = 100 + (rate − 100) · min(pulse, HOT) / HOT`, `HOT = 6e18`, `rate` = the creator's current rate (100..500) with the same `lowerRate`, `scheduleRaise` (24 h, +1% max), `applyRaise`, `cancelRaise` and `creatorAction` wiring as `FixedRateModule`. The result is always in `100..rate`. The module is view-only and reads `hook.pulseOf`; the pulse used for a buy is the value before that buy is counted. Register it with `factory.registerModule(address(new PulseRateModule(hook)))`; existing pools keep their module.

### KeelHeart

One heartbeat for all v2 pools, deployed as `new KeelHeart(hook, owner)` (no external calls in the constructor). The owner (two-step `transferOwnership`/`acceptOwnership`) can only `setMinBuy(quote, rawAmount)` and `addQuote(quote)` (at most 16, no removal). There is no withdrawal, pause or override.

| Rule | Behaviour |
|---|---|
| `onBuy` | Hook only. Ignored if `minBuy[quote] == 0` or `grossQuoteIn < minBuy[quote]`. If a round is over (`deadline != 0 && now >= deadline`) it is ended first. With no round running: `deadline = now + 300`, round number +1. Otherwise `deadline = min(deadline + 30, now + 600)`. Records `lastBuyer`, `lastToken`, `lastTokens = tokensOut`. Emits `Beat(round, buyer, token, quote, grossQuoteIn, deadline)`. |
| `fund(quote, amount)` | Anyone, listed quotes only. ETH via `msg.value` (`quote = address(0)`), ERC20 via `transferFrom` with an exact balance-change check. Adds to the running pot. Emits `Funded(round, quote, from, amount)`. |
| `end()` | Anyone once `now >= deadline`; a running round always has a buyer. Winner = `lastBuyer`, eligible iff `lastToken.balanceAt(winner, block.number − 1) >= lastTokens`. `balanceAt` still reverts for the current block, so nothing done inside the `end()` block (or the block of the buy that ends a round) can count. Eligible: every listed quote's prize is 70% of its pot, 30% carries over. Not eligible: nothing is awarded and the whole pot carries over. Emits `Flatline(round, winner, eligible)`. The next round starts on the next counted buy. |
| `claim(round, to)` | Winner only, once, pays every quote's prize to `to` with exact transfer checks, `nonReentrant`, and a solvency check `balance >= liability` (pot + unpaid prizes) before and after each payout. Emits `Claimed(round, winner, to)`. |
| Views | `state()` → `(round, deadline, lastBuyer, lastToken)`; `quoteList()`; `potOf(quote)`; `minBuy(quote)`; `prizeOf(round, quote)`; `result(round)` → `(winner, token, endBlock, eligible, claimed)`; plus `lastTokens()`, `eligibleRounds()`, `liability(quote)`, `anchorCount(quote)`. |

Pots are split lazily. Ending a round stores only its result and, when eligible, its ordinal among eligible rounds. Each quote keeps a short list of funding anchors `(ordinal, amount)`: funding settles the pot through the current ordinal and records the new total. `potOf` and `prizeOf` walk forward from the latest anchor before the requested ordinal, taking 70% per eligible round; the walk stops once a prize rounds to zero. This keeps `onBuy` O(1) regardless of how many quotes are listed and makes claims cost O(quotes) with no per-round loop in the hot path. `liability[quote] = funded − claimed` equals `potOf + Σ unpaid prizes` at all times (invariant-tested).

### Gas

`forge snapshot --match-contract GasWith` (`.gas-snapshot`). Each test is exactly one swap of 0.01 ETH through the test router after an identical setup, so the totals include the router's own overhead and are comparable across rows. The "with heart" column has a funded heart with `minBuy(ETH) = 0.001 ether`.

| Swap through the test router | No heart set | Heart set |
|---|---:|---:|
| Plain buy (empty hookData) | 319,609 | 324,064 |
| Router buy naming a buyer (counted → round starts) | 345,370 | 404,615 |
| Non-router buy with a 32-byte payload (ignored) | 345,311 | 354,438 |
| Sell | 428,684 | 428,615 |
| Two counted buys, second one extends the running round | — | 662,489 (second buy ≈ 258k, warm) |
| Two counted buys, second one ends round 1 inside `onBuy` and starts round 2 | — | 781,900 (second buy ≈ 377k, warm) |

Direct `heart.onBuy` cost measured from the hook's call site (`test_onBuyGasOnEveryPath`, asserted ≤ 120,000 on every path):

| Path | Gas |
|---|---:|
| Ignored (below `minBuy`) | 25,433 |
| Ignored (quote without threshold) | 25,645 |
| Round start | 73,885 |
| Extension | 39,677 |
| Previous round ends ineligible, new round starts | 96,760 |
| Previous round ends eligible (winner with 400 checkpoints), new round starts | 119,766 |

The eligible-end path grows by about 2,100 gas each time the winner's checkpoint history doubles (one storage read per binary-search step). With the 200,000 stipend as the hard ceiling, a history of more than roughly 2^38 checkpoints would be needed before the heart call fails, in which case the swap still succeeds and `HeartCallFailed` is emitted.

Extra cost of a counted buy over part 1: a plain buy with no heart set costs about 8k more than the part 1 swap (one warm pulse write and one `factory.heart()` read; the first buy of a pool pays a cold 22k pulse slot instead). A counted buy with the heart running costs **about 85k more than a plain buy** (404,615 vs 319,609): the `router()` read, the `minBuy` read, the 200k-stipend call and the heart's own 74k round-start work. Ending a round inside `onBuy` adds up to another ~46k.

### After launch (part 2a settings)

| Setter | Value | Where the owner gets it |
|---|---|---|
| `factory.setSigner(signer)` | The address of the off-chain permit signer. Required before any launch. | The backend key that computes start ticks for the $5,000 market cap. |
| `factory.setLaunchFee(fee)` | Optional; default 0.0001 ether, at most 0.01 ether. | Product decision. |
| `factory.setRouter(router)` | The production router that forwards `abi.encode(buyer)` as hook data. Once only. | The router deployment of the site (not the test router). |
| `factory.setHeart(heart)` | The deployed `KeelHeart(hook, owner)`. Once only. | The heart deployment; constructor needs the hook address and the owner multisig. |
| `heart.addQuote(quote)` | Each quote whose pot the heart should hold (ETH is `address(0)`), at most 16, never removable. | Same allowlist as `configureQuote`. |
| `heart.setMinBuy(quote, raw)` | Gross raw-unit threshold for a buy to count. Zero means buys of that quote never count. | Product decision per quote. |
| `factory.registerModule(pulseModule)` | Optional: switch future launches to `PulseRateModule(hook)`. | Deployed module bound to this hook. |

Operational notes: the heart's eligibility rule reads the end-of-previous-block balance, so a winner must hold `lastTokens` through the block before `end()` or the ending buy; tokens received by transfer count, tokens moved inside the ending block do not. Anyone can call `end()`; the site should do so promptly after the deadline because a late counted buy also ends the round (and starts a new one owned by that buyer). Pots are only ever paid to winners; the owner cannot move them. The router must send exactly `abi.encode(buyer)`; a payload with dirty upper bytes reverts that router swap only. The heart holds every listed quote in one contract, so the same owner attestation that applies to `configureQuote` (standard, non-rebasing tokens) applies to `addQuote`.

## Contracts and parameters

| Contract / operation | Parameters and meaning |
|---|---|
| `KeelV2Token(name, symbol)` | Constructor-only configuration. Mints exactly `10^27` minor units to its deploying factory. 18 decimals. |
| `KeelV2Factory(poolManager, owner, teamRecipient)` | Nonzero v4 manager, explicit multisig owner, initial nonzero team beneficiary. No external constructor calls. |
| `KeelV2Hook(poolManager, factory)` | Nonzero manager and immutable factory. Its address must carry exactly permission bits `0x18cc`. |
| `FixedRateModule(hook)` | Immutable nonzero hook. No owner or funds-moving methods. |
| `factory.initialize(hook, module)` | One-time wiring by the contract that constructed the factory, called atomically by the dry-run script. Verifies manager/factory/module bindings. The bootstrap has no subsequent authority. |
| `factory.launch(name, symbol, metadata, quote, startTick, baseFeeBps, deadline, signature)` | Name 1–64 bytes, symbol 1–16 bytes, metadata 0–2048 bytes. Metadata is uninterpreted and immutable. Quote must be allowlisted. Rate 100–500 bps. Tick must be a multiple of 60 inside the quote's allowed interval. `msg.value == launchFee`, forwarded to the team. `deadline` and `signature` form the EIP-712 permit described in part 2a. Returns `(token, poolId)`. Caller is creator. |
| `hook.rates(poolId, isBuy, context)` | Current module base rate and effective rate, in bps. The module receives the swap's hook data unchanged. FixedRateModule ignores direction/context. |
| `hook.splitFee(amount, base, effective)` | Pure raw-unit fee calculator. `100 <= base <= 500`, `base <= effective <= 9900`. Returns total fee and creator share. |
| `module.lowerRate(poolId, newRate)` | Creator only, strictly lower, at least 100 bps; cancels a pending raise. |
| `module.scheduleRaise(poolId, newRate)` | Creator only, strictly greater than current, at most current +100 bps and at most 500 bps. Schedules for current time +24 hours. Replacing a pending raise resets its delay. |
| `module.applyRaise(poolId)` | Creator only, applies a pending raise at or after its deadline. Explicit application is required; merely passing the deadline does not change the rate. |
| `module.cancelRaise(poolId)` | Creator only, cancels a pending raise; reverts if none exists. |
| `hook.transferCreator(token, newCreator)` | Current creator only, nonzero successor. Updates activity. Pending rate proposals belong to the pool; only the successor can apply/cancel them afterward. |
| `hook.ping(token)` | Current creator only, updates activity. |
| `hook.creatorAction(poolId, actor)` | Only that pool's module; validates the current creator and updates activity for rate actions. |
| `hook.setCreatorByTakeover(token, newCreator)` | Only the once-configured takeover contract; nonzero successor and strictly more than 30 days since last activity. The hook enforces inactivity itself. |
| `hook.claimCreator(token, to)` | Claims the caller's earned credit for that token, including former creators. Nonzero recipient other than the hook; contracts are supported. Updates activity only when the caller is still creator. |
| `hook.claimTeam(quote, to)` | Claims the caller's earned team credit for that quote, including former team recipients. Same destination constraints. |
| `token.transfer(to, amount)` | Standard transfer; nonzero destination. Self-transfers and zero transfers are supported. |
| `token.approve(spender, amount)` | Nonzero spender; replaces allowance. Maximum uint256 allowance remains unlimited until changed. |
| `token.transferFrom(from, to, amount)` | Checks/decrements allowance except maximum allowance, then transfers. |
| `token.balanceAt(account, blockNumber)` | Balance at the end of a completed block. Current/future blocks revert `UnfinalizedBlock`; before the first checkpoint returns zero. |

Useful read methods include `factory.launchInfo(token)` (key, bounds, locked liquidity, exact liquidity tokens, dust, metadata), `factory.quotes(quote)`, `hook.poolInfo(poolId)`, `hook.poolIdOf(token)`, `hook.creatorFees(token, beneficiary)`, `hook.teamFees(quote, beneficiary)`, `hook.totalUnclaimed(quote)`, `hook.creatorEarned(poolId)`, `hook.teamEarned(poolId)`, `module.rates(poolId)` (current, pending, deadline), and `token.checkpointCount(account)`.

The internal integration entry points are authenticated, not user APIs:

- `hook.registerPool(key, token, quote, creator, module, baseFeeBps, decaySeconds)` is factory-only and binds all seven values once. `key` is the v4 tuple `(currency0, currency1, fee, tickSpacing, hooks)`; currencies are sorted addresses, native ETH is zero, fee is zero and tick spacing is 60.
- `factory.unlockCallback(data)` is manager-only during an active launch. `data` encodes the newly created token address; stored launch information determines the entire liquidity operation.
- The manager-only callbacks are `afterInitialize(sender,key,sqrtPriceX96,tick)`, `beforeAddLiquidity(sender,key,params,hookData)`, `beforeSwap(sender,key,params,hookData)` and `afterSwap(sender,key,params,delta,hookData)`. `sender` is the direct manager caller. Initialization uses Q64.96 square-root price and the resulting tick. Liquidity parameters are `(tickLower,tickUpper,liquidityDelta,salt)`. Swap parameters are `(zeroForOne,amountSpecified,sqrtPriceLimitX96)`, with negative amount meaning exact input. `delta` is v4's signed currency0/currency1 core swap amounts. Hook data is forwarded as module context for swaps; FixedRateModule ignores it. Disabled callbacks have no implementation.

### Token instances and checkpoints

“Clone” is implemented as an identical **full-code instance**, created by the factory with `new KeelV2Token`. EIP-1167 minimal proxies require `DELEGATECALL`, which the brief prohibits. Full-code instances cost more deployment gas, have no implementation address or initializer, and cannot be upgraded. There is no owner, post-constructor mint, burn, freeze, tax, transfer limit or privileged token function.

Each balance change writes a checkpoint, including factory mint/transfer and PoolManager settlement. Multiple changes in the same block overwrite the last checkpoint, yielding the end-of-block balance once the next block starts. Binary search reads history. These are raw token balances, not beneficial LP ownership; PoolManager is a singleton and its checkpoint aggregates actual holdings across any pools using the token. Current-block history cannot be finalized on chain and is therefore rejected.

### Price, liquidity and dust

`startTick` always describes **raw quote units per raw token unit**, independent of address sorting. The human price of one token is `1.0001^startTick * 10^(18 - quoteDecimals)`. Tick spacing is fixed at 60, LP fee is zero, and the range extends upward in this economic price direction to the maximum usable tick, 887220. If token is currency0, the actual range is `[startTick, 887220]`; otherwise it is `[-887220, -startTick]`. Initialization is at the token-only boundary, so the creator provides no quote liquidity.

The factory adds the largest integer liquidity representable by the supply in that range. It transfers **every supply unit** into PoolManager. Integer-liquidity rounding can leave a small remainder: this is settled and then permanently `clear`ed in PoolManager, not paid to the creator or an administrator. `LiquidityLocked` and `launchInfo` report the exact principal and remainder. This is the necessary quantization qualification to “whole supply in liquidity.” Extreme allowed ticks can cause liquidity overflow, exceed Uniswap's per-tick maximum, or create economically unusable prices; launch reverts on arithmetic/protocol bounds. The owner must choose sensible per-quote tick bounds. There is no initial minimum market cap oracle.

The position owner is the factory. Only the factory can add liquidity through this hook, and its only liquidity operation is atomic launch. There is no remove, position-transfer, generic call, approval, or LP-fee collection path. Outside negative liquidity changes fail because the caller has no position. The required permission mask has no remove-liquidity callback; locking relies on v4's position ownership and the immutable factory. Permissionless v4 donations do not unlock or enlarge the position and are irretrievable here.

### Fees and launch schedule

All calculations use quote **minor units**, so 6, 8 and 18 decimals follow the same integer formulas. Buy means quote input; sell means token input. Positive/exact-output `amountSpecified` is rejected. Exact-input magnitude is bounded to positive int128 capacity.

For gross quote input on a buy or gross quote output on a sell:

```
baseFee      = ceil(quoteAmount * baseBps / 10_000)
totalFee     = ceil(quoteAmount * effectiveBps / 10_000)
creatorShare = floor(baseFee * 80 / 100)
teamShare    = totalFee - creatorShare
```

Thus all extra launch fee goes to the team, including rounding remainder. There are no wallet exemptions. Meme tokens are never swapped or collected by the hook for fees. Fees are transferred from PoolManager into the hook and credited to beneficiaries when earned. Per-pool earnings are cumulative; creator claims are per-token, team claims aggregate the beneficiary's pools sharing a quote. Team claims do not retrospectively allocate withdrawals among pool earnings counters.

Launch configuration is copied into the pool. Duration is 30–600 seconds, default 120. The launch line is anchored to the **original launch base rate**, using conservative upward integer rounding:

```
t = currentTimestamp - launchedAt
while t < decaySeconds:
    scheduled = launchBase + ceil((9900 - launchBase) * (decaySeconds - t) / decaySeconds)
    effective = max(scheduled, currentModuleBase)
afterward:
    effective = currentModuleBase
```

Lowering the base changes the creator's base share immediately, but does not reset the launch clock or rewrite its line. At expiry the launch overlay ends, including its original-base floor. This interpretation is explicit because a lower base during launch otherwise leaves an ambiguous endpoint. Raises need 24 hours, longer than every launch schedule.

Buys charge input fees in `beforeSwap`; sells charge output fees in `afterSwap`, using v4 return deltas. A buy snapshots its net input before execution, so a future module is not queried again after pool state or fee balances change. Buys that cannot consume the requested post-fee input because of a price limit or exhausted liquidity revert atomically, so no fee is retained for a partial buy. Sells can partially fill and charge only actual quote output. Tiny buys whose rounded fee consumes the whole input revert; a tiny sell can have its entire quote output consumed by rounding.

**Router responsibility:** PoolManager must have actual quote inventory when `take` is called. A router should settle input before calling `swap`, especially for a newly introduced quote with no other v4 inventory. The test router demonstrates this using its own prefunded balance. It is test scaffolding, not a production router: production routing must add deadlines, slippage/minimum-output protection and user-facing quote handling. Standard routers that settle only afterward can fail if PoolManager lacks quote inventory. Mainnet v4 protocol governance, quote-token pauses and external token upgrades are outside Keel's control.

## Owner powers

The factory has two-step ownership and no renounce operation. Ownership never defaults to the deployment caller.

| Owner method | Scope |
|---|---|
| `transferOwnership(next)` / successor's `acceptOwnership()` | Nonzero pending successor; owner remains unchanged until acceptance. A new proposal replaces the pending one. |
| `setLaunchesPaused(bool)` | New launches only. Existing trading, creator actions and claims remain available. |
| `configureQuote(quote, enabled, minStartTick, maxStartTick, hasTransferFee, rebases)` | New launches only. Tick bounds must be ordered, multiples of 60, and strictly inside ±887220. ETH is address zero and 18 decimals. On enabling a quote, ERC20 decimals are queried and must be 6, 8 or 18. Disabling preserves recorded decimals without calling a potentially broken token. Either nonstandard-token flag being true is rejected. |
| `setDecaySeconds(seconds)` | 30–600; future launches only. |
| `registerModule(module)` | Must have code and report this hook. Sets the module for future launches only. No existing pool module can be reassigned. |
| `setTeamRecipient(next)` | Nonzero beneficiary of future team earnings, including existing pools. Existing credits remain owned and claimable by the former recipient. |
| `setTakeoverContract(contract)` | Nonzero contract with code, once only; no replacement or clearing. Unset by the deployment script for this part. Must still satisfy the hook's strict inactivity check. |

The owner cannot change an existing pool's module, creator rate, fixed split, creator directly, launch timestamp/duration, locked position, metadata, or already accrued fees. There are no sweep, rescue, withdraw-all, proxy-upgrade or arbitrary-call methods. The takeover module is a deliberately delegated power over **future** creator earnings after inactivity, not a withdrawal power. Creator actions that refresh activity are successful rate changes/schedules/cancellations/applications, ping, creator transfer, and claims by the current creator. Trading through a router and a former creator's claims do not refresh it.

## After launch / operator responsibilities

1. Use the intended chain's verified v4 PoolManager. Supply the actual owner multisig and team recipient explicitly. Constructor values are not guessed by the script.
2. Review each quote's semantics and then call `configureQuote`. The flags are an **owner attestation**, not magical ERC20 introspection. Generic ERC20 interfaces cannot prove the absence of a future rebase or transfer tax. Known taxed/rebasing assets must never be enabled. Exact balance-change checks reject taxed transfers when collecting or paying fees; solvency checks reject a deficient balance, but a negative rebase could make custody insolvent without any Keel call. Upgradeable quotes such as USDC retain their issuer risks. Disable a quote for future launches when necessary; existing pools deliberately cannot be administratively rewritten or frozen.
3. Choose tick bounds in raw-unit price space, separately for each decimal scale, and review realistic execution prices. Default initialization does not allowlist any quote.
4. Review all future modules as immutable, non-custodial contracts with no owner rate override. An interface cannot prove arbitrary external bytecode has these semantics. Keel uses a normal initialization call and **STATICCALL** fee queries, no approvals or delegatecalls; returned base rates are bounded to 100–500 bps. A reverting or malicious module can obstruct its own pools. The included FixedRateModule has no administrator and is not upgradeable.
5. Configure the final takeover contract only after part 2 is implemented and independently reviewed. Do not use a temporary stand-in: the address cannot be changed.
6. A production frontend/router must expose the high initial fee, slippage and partial-buy policy. Creators should monitor activity and proposed raises. Beneficiaries pull their fees to their chosen addresses; a recipient that rejects transfers affects only that claim.
7. Commission an independent security review before handling funds. Local tests and the self-review in `REVIEW.md` are not an independent audit.

## Dry run script

`script/Deploy.s.sol:Deploy` exposes `run(owner, teamRecipient, poolManager, chainId)` and `deploy(Config)`. The chain guard requires exact equality with `block.chainid`; manager code must exist. It creates a factory, searches up to 500,000 CREATE2 salts, creates the hook at a permission-correct address, creates FixedRateModule and initializes wiring atomically. `mine(deployer, initCodeHash, start, attempts)` exposes the bounded search. The owner and team must be nonzero. The script never calls `startBroadcast`, reads the environment, or accesses a key. The script itself is simulation infrastructure, not a contract to deploy on chain.

An operator can substitute actual addresses in this simulation command; do **not** add `--broadcast`:

```sh
forge script script/Deploy.s.sol:Deploy \
  --sig 'run(address,address,address,uint256)' \
  '<OWNER_MULTISIG>' '<TEAM_RECIPIENT>' \
  0x000000000004444c5dc75cB358380D2e3dE08A90 1 \
  --fork-url https://eth.llamarpc.com --fork-block-number 22000000
```

CREATE2 salt/address results depend on the script's deployer address, compiler settings, constructor values and bytecode. This dry run is not a broadcast/deployer design for a later release. Deployment must preserve the wiring and recompute addresses for its actual deployment mechanism.

## Events

| Emitter | Events and fields |
|---|---|
| Token | `Transfer(from,to,value)`, `Approval(owner,spender,value)`; mint emits Transfer from zero; finite allowance spending emits Approval. |
| Factory ownership | `OwnershipTransferStarted(previousOwner,pendingOwner)`, `OwnershipTransferred(previousOwner,newOwner)`. |
| Factory configuration | `Initialized(hook,module)`, `LaunchPauseChanged(paused)`, `QuoteConfigured(quote,enabled,decimals,minStartTick,maxStartTick)`, `DecayChanged(decaySeconds)`, `ModuleRegistered(module)`, `TeamRecipientChanged(previousRecipient,newRecipient)`, `TakeoverContractSet(takeoverContract)`. |
| Factory launch | `Launched(token,poolId,creator,quote,startTick,baseFeeBps,metadata)`, `LiquidityLocked(token,liquidity,liquidityTokens,lockedDust)`. |
| Hook registration/fees | `PoolRegistered(poolId,token,creator,quote,module,baseFeeBps,decaySeconds)`, `FeesAccrued(poolId,creator,team,creatorAmount,teamAmount)`. |
| Hook claims | `CreatorClaimed(token,beneficiary,to,amount)`, `TeamClaimed(quote,beneficiary,to,amount)`. |
| Hook creator role | `CreatorTransferred(token,previousCreator,newCreator,takeover)`, `CreatorActivity(token,creator,timestamp)`. |
| Rate module | `RateInitialized(poolId,rate)`, `RateLowered(poolId,rate)`, `RaiseScheduled(poolId,rate,applyAfter)`, `RaiseCancelled(poolId)`, `RaiseApplied(poolId,rate)`. |
| Script | `DryRunComplete(factory,hook,module,hookSalt)`. |

## Dependencies and licenses

Vendored Uniswap v4-core **1.0.2** comes from its published npm archive, including its Solmate `Owned.sol` dependency and licenses. Forge Standard Library is pinned to **v1.9.7**, commit `77041d2ce690e692d6e03cc812b57d1ddaa4d505`. Two explicit v4 arithmetic compatibility changes and their regression tests are recorded in [lib/VENDORED.md](lib/VENDORED.md). No submodules, remote imports or package installation are needed for verification. Keel source is MIT licensed. Preserve each dependency's own file-level license, including v4-core's BUSL-1.1 implementation license; the manager is included for tests, while production Keel calls an existing manager.

Protocol reference: [Uniswap custom accounting](https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting) and the vendored [v4-core source](https://github.com/Uniswap/v4-core).
