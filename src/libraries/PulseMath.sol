// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Exponential decay with a one-hour half-life. Never reverts for any input.
library PulseMath {
    uint256 internal constant HALF_LIFE = 1 hours;
    uint256 internal constant MAX_HALF_LIVES = 64;
    uint256 internal constant ONE = 1 << 64;

    /// @dev 2^(-2^-(i+1)) in Q64 for i = 0..15, so a 16-bit fraction of a half-life resolves to ~1e-5.
    uint256 private constant C0 = 13043817825332782212;
    uint256 private constant C1 = 15511800964685064948;
    uint256 private constant C2 = 16915738899553466670;
    uint256 private constant C3 = 17664662643191237676;
    uint256 private constant C4 = 18051468387014017850;
    uint256 private constant C5 = 18248035989933441396;
    uint256 private constant C6 = 18347121020861646923;
    uint256 private constant C7 = 18396865112328554661;
    uint256 private constant C8 = 18421787711448657617;
    uint256 private constant C9 = 18434261669329232139;
    uint256 private constant C10 = 18440501815349552981;
    uint256 private constant C11 = 18443622680442407997;
    uint256 private constant C12 = 18445183311048607332;
    uint256 private constant C13 = 18445963675871538003;
    uint256 private constant C14 = 18446353870663572145;
    uint256 private constant C15 = 18446548971154807802;

    /// @notice value * 2^(-elapsed / 1 hour), rounded down. `value` must fit in 128 bits.
    function decay(uint256 value, uint256 elapsed) internal pure returns (uint256) {
        if (value == 0 || elapsed >= MAX_HALF_LIVES * HALF_LIFE) return 0;
        uint256 whole = elapsed / HALF_LIFE;
        uint256 frac = ((elapsed % HALF_LIFE) << 16) / HALF_LIFE;
        return (value * exp2Neg(frac)) >> (64 + whole);
    }

    /// @notice 2^(-frac / 65536) in Q64 for frac in [0, 65536).
    function exp2Neg(uint256 frac) internal pure returns (uint256 factor) {
        factor = ONE;
        if (frac & 0x8000 != 0) factor = (factor * C0) >> 64;
        if (frac & 0x4000 != 0) factor = (factor * C1) >> 64;
        if (frac & 0x2000 != 0) factor = (factor * C2) >> 64;
        if (frac & 0x1000 != 0) factor = (factor * C3) >> 64;
        if (frac & 0x800 != 0) factor = (factor * C4) >> 64;
        if (frac & 0x400 != 0) factor = (factor * C5) >> 64;
        if (frac & 0x200 != 0) factor = (factor * C6) >> 64;
        if (frac & 0x100 != 0) factor = (factor * C7) >> 64;
        if (frac & 0x80 != 0) factor = (factor * C8) >> 64;
        if (frac & 0x40 != 0) factor = (factor * C9) >> 64;
        if (frac & 0x20 != 0) factor = (factor * C10) >> 64;
        if (frac & 0x10 != 0) factor = (factor * C11) >> 64;
        if (frac & 0x8 != 0) factor = (factor * C12) >> 64;
        if (frac & 0x4 != 0) factor = (factor * C13) >> 64;
        if (frac & 0x2 != 0) factor = (factor * C14) >> 64;
        if (frac & 0x1 != 0) factor = (factor * C15) >> 64;
    }
}
