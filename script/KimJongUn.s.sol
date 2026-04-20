// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {KimJongUn} from "../src/KimJongUn.sol";

contract KimJongUnScript is Script {
    function run() public returns (KimJongUn deployed) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        deployed = new KimJongUn();
        vm.stopBroadcast();
    }
}
