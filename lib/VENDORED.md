# Vendored source provenance

- Uniswap `@uniswap/v4-core` npm package **1.0.2**, downloaded from `https://registry.npmjs.org/@uniswap/v4-core/-/v4-core-1.0.2.tgz`. Only the recursively imported Solidity files are retained, with the package metadata and BUSL/MIT licenses.
- Solmate `src/auth/Owned.sol` and its license are from the same v4-core 1.0.2 package's bundled Solmate directory.
- Foundry `forge-std` **v1.9.7**, commit `77041d2ce690e692d6e03cc812b57d1ddaa4d505`, fetched from the official GitHub source archive. Only imported Solidity files and its MIT/Apache licenses remain.

No submodules, compiler binaries or network imports are used.

## Explicit v4 math compatibility changes

The source copy contains two small, intentional modifications; it is not an unmodified copy of the package:

1. `src/libraries/FullMath.sol`: the modular inverse starts at 1 (correct modulo 2 for every odd denominator) and performs eight Newton/Hensel lifts, rather than the original XOR-derived four-bit seed followed by six lifts. Both compute the same 256-bit inverse. This avoids Slither's `incorrect-exp` report on the intentional XOR seed. Overflow/remainder handling and the rest of the algorithm are unchanged.
2. `src/libraries/BitMath.sol`: constant-shift binary search replaces variable-shift lookup tables. Least-significant-bit lookup isolates `x & -x` and uses the same most-significant-bit search. This avoids Slither's `incorrect-shift` reports on the original intentional lookup-table shifts. Nonzero inputs and results retain the same interface and meaning.

`test/Math.t.sol` checks full-width multiplication/division identities, independent division-based bit-scan references, and all 256 power-of-two boundaries. The full offline v4 integration suite exercises the patched manager; mainnet-fork integration independently uses the already-deployed, unmodified PoolManager. These modifications do not entail deploying a new PoolManager.
