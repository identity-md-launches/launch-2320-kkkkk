// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title BitMath
/// @notice Keel vendor compatibility implementation; see lib/VENDORED.md.
/// @dev Binary search with constant shifts replaces v4's variable-shift lookup tables.
library BitMath {
    function mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0);
        unchecked {
            if (x >= (uint256(1) << 128)) {
                x >>= 128;
                r += 128;
            }
            if (x >= (uint256(1) << 64)) {
                x >>= 64;
                r += 64;
            }
            if (x >= (uint256(1) << 32)) {
                x >>= 32;
                r += 32;
            }
            if (x >= (uint256(1) << 16)) {
                x >>= 16;
                r += 16;
            }
            if (x >= (uint256(1) << 8)) {
                x >>= 8;
                r += 8;
            }
            if (x >= (uint256(1) << 4)) {
                x >>= 4;
                r += 4;
            }
            if (x >= (uint256(1) << 2)) {
                x >>= 2;
                r += 2;
            }
            if (x >= (uint256(1) << 1)) r += 1;
        }
    }

    function leastSignificantBit(uint256 x) internal pure returns (uint8) {
        unchecked {
            // The only set bit in x & -x is x's least significant one.
            return mostSignificantBit(x & (~x + 1));
        }
    }
}
