// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RouterTest} from "./support/RouterTest.sol";
import {KeelV2Token} from "../src/KeelV2Token.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev `forge snapshot --match-contract RouterGasTest`. Each test is exactly one call after identical,
///      warmed setup (heart set, every pool traded once). "Small" = 0.001 ETH, "typical" = 0.1 ETH.
///      Direct rows are a single Keel-pool or v4 swap through the part 1 test router.
contract RouterGasTest is RouterTest {
    uint256 internal constant SMALL = 0.001 ether;
    uint256 internal constant TYPICAL = 0.1 ether;
    uint256 internal smallSell;
    uint256 internal typicalSell;
    PoolKey internal ethPool;
    PoolKey internal usdcPool;

    function setUp() public virtual override {
        super.setUp();
        ethPool = factory.launchInfo(address(ethToken)).key;
        usdcPool = factory.launchInfo(address(usdcToken)).key;
        KeelV2Token[3] memory list = _tokens();
        for (uint256 i; i < 3; ++i) {
            _rbuy(buyer, list[i], 1 ether);
            _rsell(buyer, list[i], list[i].balanceOf(buyer) / 4);
            vm.prank(buyer);
            list[i].approve(address(kr), type(uint256).max);
        }
        _buy(ethPool, address(0), 1 ether);
        _buy(usdcPool, address(usdc), 3000e6);
        vm.roll(vm.getBlockNumber() + 1);
        // Token amounts worth roughly SMALL and TYPICAL ETH in the ETH pool.
        typicalSell = ethToken.balanceOf(buyer) / 7;
        smallSell = typicalSell / 100;
    }

    function _sellAmount(KeelV2Token token, uint256 ofEthPoolAmount) internal view returns (uint256) {
        return token.balanceOf(buyer) * ofEthPoolAmount / ethToken.balanceOf(buyer);
    }

    // ---- router buys
    function test_gas_routerBuy_native_small() public {
        _rbuy(buyer, ethToken, SMALL);
    }

    function test_gas_routerBuy_native_typical() public {
        _rbuy(buyer, ethToken, TYPICAL);
    }

    function test_gas_routerBuy_v4_small() public {
        _rbuy(buyer, usdcToken, SMALL);
    }

    function test_gas_routerBuy_v4_typical() public {
        _rbuy(buyer, usdcToken, TYPICAL);
    }

    function test_gas_routerBuy_v3_small() public {
        _rbuy(buyer, btcToken, SMALL);
    }

    function test_gas_routerBuy_v3_typical() public {
        _rbuy(buyer, btcToken, TYPICAL);
    }

    // ---- router sells (approval already given)
    function test_gas_routerSell_native_small() public {
        vm.prank(buyer);
        kr.sell(address(ethToken), smallSell, 0, _deadline());
    }

    function test_gas_routerSell_native_typical() public {
        vm.prank(buyer);
        kr.sell(address(ethToken), typicalSell, 0, _deadline());
    }

    function test_gas_routerSell_v4_small() public {
        uint256 amount = _sellAmount(usdcToken, smallSell);
        vm.prank(buyer);
        kr.sell(address(usdcToken), amount, 0, _deadline());
    }

    function test_gas_routerSell_v4_typical() public {
        uint256 amount = _sellAmount(usdcToken, typicalSell);
        vm.prank(buyer);
        kr.sell(address(usdcToken), amount, 0, _deadline());
    }

    function test_gas_routerSell_v3_small() public {
        uint256 amount = _sellAmount(btcToken, smallSell);
        vm.prank(buyer);
        kr.sell(address(btcToken), amount, 0, _deadline());
    }

    function test_gas_routerSell_v3_typical() public {
        uint256 amount = _sellAmount(btcToken, typicalSell);
        vm.prank(buyer);
        kr.sell(address(btcToken), amount, 0, _deadline());
    }

    // ---- direct single-pool swaps through the minimal test router
    function test_gas_directKeelBuy_eth_small() public {
        _buy(ethPool, address(0), SMALL);
    }

    function test_gas_directKeelBuy_eth_typical() public {
        _buy(ethPool, address(0), TYPICAL);
    }

    function test_gas_directKeelSell_eth_small() public {
        _sell(ethPool, address(ethToken), smallSell);
    }

    function test_gas_directKeelSell_eth_typical() public {
        _sell(ethPool, address(ethToken), typicalSell);
    }

    function test_gas_directKeelBuy_usdc_small() public {
        _buy(usdcPool, address(usdc), 3e6);
    }

    function test_gas_directKeelBuy_usdc_typical() public {
        _buy(usdcPool, address(usdc), 300e6);
    }

    function test_gas_directV4Hop_ethToUsdc_typical() public {
        _buy(usdcKey, address(0), TYPICAL);
    }
}
