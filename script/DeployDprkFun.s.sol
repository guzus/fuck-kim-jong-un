// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {KimJongUn} from "../src/KimJongUn.sol";
import {DprkPass} from "../src/launchpad/DprkPass.sol";
import {DprkLaunchpad} from "../src/launchpad/DprkLaunchpad.sol";
import {MockWBNB} from "../test/launchpad/mocks/MockWBNB.sol";
import {MockPancakeFactory} from "../test/launchpad/mocks/MockPancakeV2.sol";

/// @notice Deploys the DPRK.FUN launchpad stack. See docs/BSC_LAUNCHPAD.md ("Deployment script").
///
///   anvil --port 8546
///   forge script script/DeployDprkFun.s.sol --rpc-url http://127.0.0.1:8546 --broadcast --private-key <key>
///
/// Env (all optional):
///   KIM_JONG_UN_ADDRESS   reuse an existing registry (otherwise a new one is deployed)
///   FEE_RECIPIENT         default: deployer
///   OWNER                 launchpad owner (pause / fee recipient); default: deployer
///   FEE_BPS               default 100 (max 500)
///   INITIAL_VIRTUAL_BNB   V0 in wei; default 8 ether (56), 0.5 ether (97), 1 ether (other chains)
///   PASS_NAME, PASS_SYMBOL default "DPRK.FUN Not-Lazarus Pass" / "NOTLAZ"
///   DEPLOYMENTS_FILE      default deployments/<chainId>.json (use e.g. deployments/56-fork.json for fork runs)
/// Chains 56 and 97 use the real PancakeSwap V2 factory and WBNB. Any other chain gets MockWBNB and a mock
/// PancakeSwap V2 factory.
contract DeployDprkFun is Script {
    address internal constant BSC_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address internal constant BSC_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant BSC_TESTNET_FACTORY = 0x6725F303b657a9451d8BA641348b6761A6CC7a17;
    address internal constant BSC_TESTNET_WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;

    struct Deployment {
        uint256 chainId;
        address kimJongUn;
        address pass;
        address launchpad;
        address pancakeFactory;
        address wbnb;
        uint256 deployBlock;
    }

    function run() external returns (Deployment memory d) {
        d.chainId = block.chainid;
        // Lower bound for log queries: the deployment lands in this block or a later one.
        d.deployBlock = block.number;

        vm.startBroadcast();
        (VmSafe.CallerMode mode, address deployer,) = vm.readCallers();
        require(mode == VmSafe.CallerMode.RecurrentBroadcast, "DeployDprkFun: no broadcaster");

        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        address owner = vm.envOr("OWNER", deployer);
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(100));
        require(feeBps <= 500, "DeployDprkFun: FEE_BPS > 500");
        uint256 v0 = vm.envOr("INITIAL_VIRTUAL_BNB", _defaultV0(d.chainId));
        string memory passName = vm.envOr("PASS_NAME", string("DPRK.FUN Not-Lazarus Pass"));
        string memory passSymbol = vm.envOr("PASS_SYMBOL", string("NOTLAZ"));

        if (d.chainId == 56) {
            (d.pancakeFactory, d.wbnb) = (BSC_FACTORY, BSC_WBNB);
        } else if (d.chainId == 97) {
            (d.pancakeFactory, d.wbnb) = (BSC_TESTNET_FACTORY, BSC_TESTNET_WBNB);
        } else {
            d.wbnb = address(new MockWBNB());
            d.pancakeFactory = address(new MockPancakeFactory(deployer));
        }
        require(d.pancakeFactory.code.length != 0 && d.wbnb.code.length != 0, "DeployDprkFun: no PancakeSwap here");

        d.kimJongUn = vm.envOr("KIM_JONG_UN_ADDRESS", address(0));
        if (d.kimJongUn == address(0)) {
            d.kimJongUn = address(new KimJongUn());
        } else {
            require(d.kimJongUn.code.length != 0, "DeployDprkFun: KIM_JONG_UN_ADDRESS has no code");
        }

        d.pass = address(new DprkPass(d.kimJongUn, passName, passSymbol));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 feeBps16 = uint16(feeBps); // <= 500, checked above
        d.launchpad = address(new DprkLaunchpad(d.pass, d.pancakeFactory, d.wbnb, feeRecipient, owner, v0, feeBps16));
        vm.stopBroadcast();

        _write(d);
        _print(d, owner, feeRecipient, v0, feeBps);
    }

    function _defaultV0(uint256 chainId) internal pure returns (uint256) {
        if (chainId == 56) return 8 ether;
        if (chainId == 97) return 0.5 ether;
        return 1 ether;
    }

    function _write(Deployment memory d) internal {
        string memory path = vm.envOr(
            "DEPLOYMENTS_FILE", string.concat(vm.projectRoot(), "/deployments/", vm.toString(d.chainId), ".json")
        );
        vm.createDir(string.concat(vm.projectRoot(), "/deployments"), true);
        string memory key = "deployment";
        vm.serializeUint(key, "chainId", d.chainId);
        vm.serializeAddress(key, "kimJongUn", d.kimJongUn);
        vm.serializeAddress(key, "pass", d.pass);
        vm.serializeAddress(key, "launchpad", d.launchpad);
        vm.serializeAddress(key, "pancakeFactory", d.pancakeFactory);
        vm.serializeAddress(key, "wbnb", d.wbnb);
        string memory json = vm.serializeUint(key, "deployBlock", d.deployBlock);
        vm.writeJson(json, path);
        console.log("wrote", path);
    }

    function _print(Deployment memory d, address owner, address feeRecipient, uint256 v0, uint256 feeBps)
        internal
        view
    {
        console.log("");
        console.log("owner        ", owner);
        console.log("feeRecipient ", feeRecipient);
        console.log("feeBps       ", feeBps);
        console.log("V0 (wei)     ", v0);
        console.log("graduationBnb", DprkLaunchpad(d.launchpad).graduationBnb());
        console.log("pancakeFactory", d.pancakeFactory);
        console.log("wbnb         ", d.wbnb);
        console.log("");
        console.log("# frontend/.env.local");
        console.log(string.concat("VITE_LAUNCHPAD_CHAIN_ID=", vm.toString(d.chainId)));
        if (d.chainId != 56 && d.chainId != 97) {
            console.log("# local node: set this to the RPC you deployed to");
            console.log("VITE_LAUNCHPAD_RPC_URL=http://127.0.0.1:8545");
        }
        console.log(string.concat("VITE_DPRK_KIM_JONG_UN_ADDRESS=", vm.toString(d.kimJongUn)));
        console.log(string.concat("VITE_DPRK_PASS_ADDRESS=", vm.toString(d.pass)));
        console.log(string.concat("VITE_DPRK_LAUNCHPAD_ADDRESS=", vm.toString(d.launchpad)));
        console.log(string.concat("VITE_DPRK_DEPLOY_BLOCK=", vm.toString(d.deployBlock)));
    }
}
