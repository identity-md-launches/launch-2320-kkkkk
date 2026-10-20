// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";

contract MathTest is Test {
    function testFuzz_fullWidthMultiplicationAndDivision(uint256 x, uint256 denominator) public pure {
        if (denominator == 0) denominator = 1;
        assertEq(FullMath.mulDiv(x, denominator, denominator), x);
        uint256 ceilQuotient = x / denominator + (x % denominator == 0 ? 0 : 1);
        // x*(d-1)/d = x - x/d, with rounding reversed by the subtraction.
        assertEq(FullMath.mulDiv(x, denominator - 1, denominator), x - ceilQuotient);
        assertEq(FullMath.mulDivRoundingUp(x, denominator - 1, denominator), x - x / denominator);
    }

    function testFuzz_bitScansAgainstDivisionReference(uint256 x) public pure {
        if (x == 0) x = 1;
        uint256 value = x;
        uint256 most;
        while (value > 1) {
            value /= 2;
            ++most;
        }
        value = x;
        uint256 least;
        while (value % 2 == 0) {
            value /= 2;
            ++least;
        }
        assertEq(BitMath.mostSignificantBit(x), most);
        assertEq(BitMath.leastSignificantBit(x), least);
    }

    function test_allPowerOfTwoBoundaries() public pure {
        for (uint256 i; i < 256; ++i) {
            uint256 value = uint256(1) << i;
            assertEq(BitMath.mostSignificantBit(value), i);
            assertEq(BitMath.leastSignificantBit(value), i);
            if (i > 0) assertEq(BitMath.mostSignificantBit(value - 1), i - 1);
        }
        assertEq(FullMath.mulDiv(type(uint256).max, type(uint256).max, type(uint256).max), type(uint256).max);
    }
}
