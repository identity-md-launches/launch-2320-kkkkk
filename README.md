# Keel v2 — contracts, part 1

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

## Contracts and parameters

| Contract / operation | Parameters and meaning |
|---|---|
| `KeelV2Token(name, symbol)` | Constructor-only configuration. Mints exactly `10^27` minor units to its deploying factory. 18 decimals. |
| `KeelV2Factory(poolManager, owner, teamRecipient)` | Nonzero v4 manager, explicit multisig owner, initial nonzero team beneficiary. No external constructor calls. |
| `KeelV2Hook(poolManager, factory)` | Nonzero manager and immutable factory. Its address must carry exactly permission bits `0x18cc`. |
| `FixedRateModule(hook)` | Immutable nonzero hook. No owner or funds-moving methods. |
| `factory.initialize(hook, module)` | One-time wiring by the contract that constructed the factory, called atomically by the dry-run script. Verifies manager/factory/module bindings. The bootstrap has no subsequent authority. |
| `factory.launch(name, symbol, metadata, quote, startTick, baseFeeBps)` | Name 1–64 bytes, symbol 1–16 bytes, metadata 0–2048 bytes. Metadata is uninterpreted and immutable. Quote must be allowlisted. Rate 100–500 bps. Tick must be a multiple of 60 inside the quote's allowed interval. Returns `(token, poolId)`. Caller is creator. No ETH/payment is accepted at launch. |
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
