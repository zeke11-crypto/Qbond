// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {QBondEscrow} from "../src/QBondEscrow.sol";
import {QBondIdentityRegistry} from "../src/mocks/QBondIdentityRegistry.sol";

contract DeployQBond is Script {
    address constant DEFAULT_TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address tusd8 = vm.envOr("TUSD8_ADDRESS", DEFAULT_TUSD8);
        address registry = vm.envOr("ERC8004_IDENTITY_REGISTRY", address(0));

        vm.startBroadcast(deployerKey);

        if (registry == address(0)) {
            QBondIdentityRegistry deployedRegistry = new QBondIdentityRegistry();
            registry = address(deployedRegistry);
            console2.log("Deployed QBondIdentityRegistry:", registry);
        } else {
            console2.log("Using existing ERC-8004 IdentityRegistry:", registry);
        }

        QBondEscrow escrow = new QBondEscrow(tusd8, registry);
        console2.log("Deployed QBondEscrow:", address(escrow));
        console2.log("Pinned tUSD8:", tusd8);

        vm.stopBroadcast();
    }
}
