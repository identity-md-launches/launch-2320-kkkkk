// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {KeelV2Factory} from "../src/KeelV2Factory.sol";
import {KeelV2Hook} from "../src/KeelV2Hook.sol";
import {FixedRateModule} from "../src/FixedRateModule.sol";

/// @notice Simulation only: no broadcast cheatcodes, environment access, or private keys.
contract Deploy is Script {
    error WrongChain();
    error InvalidConfig();
    error SaltNotFound();

    struct Config {
        address owner;
        address teamRecipient;
        IPoolManager poolManager;
        uint256 chainId;
    }

    event DryRunComplete(address factory, address hook, address module, bytes32 hookSalt);

    function run(address owner, address teamRecipient, address manager, uint256 chainId)
        external
        returns (KeelV2Factory factory, KeelV2Hook hook, FixedRateModule module)
    {
        return deploy(Config(owner, teamRecipient, IPoolManager(manager), chainId));
    }

    function deploy(Config memory config)
        public
        returns (KeelV2Factory factory, KeelV2Hook hook, FixedRateModule module)
    {
        if (block.chainid != config.chainId) revert WrongChain();
        if (
            config.owner == address(0) || config.teamRecipient == address(0)
                || address(config.poolManager).code.length == 0
        ) revert InvalidConfig();
        factory = new KeelV2Factory(config.poolManager, config.owner, config.teamRecipient);
        bytes32 initHash = keccak256(
            abi.encodePacked(type(KeelV2Hook).creationCode, abi.encode(config.poolManager, address(factory)))
        );
        (bytes32 salt,) = mine(address(this), initHash, 0, 500_000);
        hook = new KeelV2Hook{salt: salt}(config.poolManager, address(factory));
        module = new FixedRateModule(address(hook));
        factory.initialize(hook, address(module));
        emit DryRunComplete(address(factory), address(hook), address(module), salt);
    }

    function mine(address deployer, bytes32 initHash, uint256 start, uint256 attempts)
        public
        pure
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash))))
            );
            if (
                uint160(predicted) & Hooks.ALL_HOOK_MASK
                    == ((1 << 12) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2))
            ) return (salt, predicted);
        }
        revert SaltNotFound();
    }
}
