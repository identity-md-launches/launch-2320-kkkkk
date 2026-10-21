// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelTest} from "./support/KeelTest.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {KeelV2Factory} from "../src/KeelV2Factory.sol";
import {KeelV2Hook} from "../src/KeelV2Hook.sol";
import {FixedRateModule} from "../src/FixedRateModule.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract DeployTest is KeelTest {
    function test_dryRunWiringExplicitOwnerAndPermissions() public {
        Deploy deployment = new Deploy();
        (KeelV2Factory nextFactory, KeelV2Hook nextHook, FixedRateModule nextModule) =
            deployment.run(successor, team, address(manager), block.chainid);
        assertEq(nextFactory.owner(), successor);
        assertEq(nextFactory.teamRecipient(), team);
        assertEq(nextFactory.takeoverContract(), address(0));
        assertEq(address(nextFactory.hook()), address(nextHook));
        assertEq(nextFactory.currentModule(), address(nextModule));
        assertEq(nextHook.factory(), address(nextFactory));
        assertEq(nextModule.hook(), address(nextHook));
        assertEq(uint160(address(nextHook)) & Hooks.ALL_HOOK_MASK, nextHook.PERMISSION_FLAGS());
        vm.startPrank(successor);
        nextFactory.configureQuote(address(0), true, -600000, 600000, false, false);
        nextFactory.setSigner(signer);
        vm.stopPrank();
        assertEq(nextFactory.router(), address(0));
        assertEq(nextFactory.heart(), address(0));
        assertEq(nextFactory.launchFee(), 0.0001 ether);
        uint256 deadline = vm.getBlockTimestamp() + 1;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerKey, nextFactory.launchDigest(successor, address(0), -230280, deadline, 0));
        vm.deal(successor, 1 ether);
        vm.prank(successor);
        nextFactory.launch{value: 0.0001 ether}(
            "kkkkk", "lllll", "", address(0), -230280, 300, deadline, abi.encodePacked(r, s, v)
        );
        assertEq(team.balance, 0.0001 ether);
    }

    function test_dryRunRejectsWrongChainAndMissingOwner() public {
        Deploy deployment = new Deploy();
        vm.expectRevert(Deploy.WrongChain.selector);
        deployment.run(owner, team, address(manager), block.chainid + 1);
        vm.expectRevert(Deploy.InvalidConfig.selector);
        deployment.run(address(0), team, address(manager), block.chainid);
        vm.expectRevert(Deploy.InvalidConfig.selector);
        deployment.run(owner, address(0), address(manager), block.chainid);
        vm.expectRevert(Deploy.InvalidConfig.selector);
        deployment.run(owner, team, outsider, block.chainid);
        vm.expectRevert(Deploy.SaltNotFound.selector);
        deployment.mine(address(deployment), bytes32(uint256(1)), 0, 0);
    }
}
