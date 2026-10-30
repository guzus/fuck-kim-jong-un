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
/// Env:
///   KIM_JONG_UN_ADDRESS   reuse an existing registry (otherwise a new one is deployed)
///   OWNER                 launchpad owner (pause, fee recipient). Required except on 97 and 31337 (default deployer)
///   FEE_RECIPIENT         required except on 97 and 31337 (default deployer)
///   FEE_BPS               default 100 (max 500)
///   INITIAL_VIRTUAL_BNB   V0 in wei. Default 8 ether (56), 0.5 ether (97), 1 ether (other chains).
///                         Allowed: [1, 100] BNB on 56 and [0.01, 100] BNB on 97.
///   PANCAKE_FACTORY, WBNB  required on any chain other than 56, 97, and 31337. They must have code. On 56/97 they
///                         may only repeat the verified addresses. On 31337 they replace the mocks when both are set.
///   PASS_NAME, PASS_SYMBOL default "DPRK.FUN Not-Lazarus Pass" / "NOTLAZ"
///   DEPLOYMENTS_FILE      default deployments/<chainId>.json (use e.g. deployments/56-fork.json for fork runs)
///
/// Mocks (MockWBNB and a mock PancakeSwap V2 factory) are only ever deployed on chain 31337. Every check runs
/// before anything is broadcast.
contract DeployDprkFun is Script {
    uint256 internal constant BSC_MAINNET = 56;
    uint256 internal constant BSC_TESTNET = 97;
    uint256 internal constant LOCAL_CHAIN = 31337;

    address internal constant BSC_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address internal constant BSC_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant BSC_TESTNET_FACTORY = 0x6725F303b657a9451d8BA641348b6761A6CC7a17;
    address internal constant BSC_TESTNET_WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;

    /// @dev Zero address / zero amount means "not set": the chain's default applies, where one exists.
    struct Config {
        address kimJongUn;
        address pancakeFactory;
        address wbnb;
        address owner;
        address feeRecipient;
        uint256 feeBps;
        uint256 initialVirtualBnb;
        string passName;
        string passSymbol;
    }

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
        d = deploy(configFromEnv());
        _write(d);
        _print(d);
    }

    function configFromEnv() public view returns (Config memory c) {
        c.kimJongUn = vm.envOr("KIM_JONG_UN_ADDRESS", address(0));
        c.pancakeFactory = vm.envOr("PANCAKE_FACTORY", address(0));
        c.wbnb = vm.envOr("WBNB", address(0));
        c.owner = vm.envOr("OWNER", address(0));
        c.feeRecipient = vm.envOr("FEE_RECIPIENT", address(0));
        c.feeBps = vm.envOr("FEE_BPS", uint256(100));
        c.initialVirtualBnb = vm.envOr("INITIAL_VIRTUAL_BNB", uint256(0));
        c.passName = vm.envOr("PASS_NAME", string("DPRK.FUN Not-Lazarus Pass"));
        c.passSymbol = vm.envOr("PASS_SYMBOL", string("NOTLAZ"));
    }

    /// @notice Validates `c` for the current chain, then broadcasts the deployment.
    function deploy(Config memory c) public returns (Deployment memory d) {
        d.chainId = block.chainid;
        // Lower bound for log queries: the deployment lands in this block or a later one.
        d.deployBlock = block.number;

        // ---- checks: nothing is broadcast unless every rule passes
        require(c.feeBps <= 500, "DeployDprkFun: FEE_BPS > 500");
        bool adminMayDefault = d.chainId == BSC_TESTNET || d.chainId == LOCAL_CHAIN;
        if (!adminMayDefault) {
            require(c.owner != address(0), "DeployDprkFun: OWNER is required on this chain");
            require(c.feeRecipient != address(0), "DeployDprkFun: FEE_RECIPIENT is required on this chain");
        }

        uint256 v0 = c.initialVirtualBnb != 0 ? c.initialVirtualBnb : _defaultV0(d.chainId);
        (uint256 minV0, uint256 maxV0) = _v0Bounds(d.chainId);
        require(v0 >= minV0 && v0 <= maxV0, "DeployDprkFun: INITIAL_VIRTUAL_BNB out of range for this chain");

        bool deployMocks;
        (d.pancakeFactory, d.wbnb, deployMocks) = _dex(d.chainId, c.pancakeFactory, c.wbnb);
        if (!deployMocks) {
            require(
                d.pancakeFactory.code.length != 0 && d.wbnb.code.length != 0,
                "DeployDprkFun: PANCAKE_FACTORY/WBNB have no code"
            );
        }
        if (c.kimJongUn != address(0)) {
            require(c.kimJongUn.code.length != 0, "DeployDprkFun: KIM_JONG_UN_ADDRESS has no code");
        }

        // ---- effects
        vm.startBroadcast();
        (VmSafe.CallerMode mode, address deployer,) = vm.readCallers();
        require(mode == VmSafe.CallerMode.RecurrentBroadcast, "DeployDprkFun: no broadcaster");

        if (deployMocks) {
            d.wbnb = address(new MockWBNB());
            d.pancakeFactory = address(new MockPancakeFactory(deployer));
        }
        d.kimJongUn = c.kimJongUn != address(0) ? c.kimJongUn : address(new KimJongUn());
        d.pass = address(new DprkPass(d.kimJongUn, c.passName, c.passSymbol));
        address owner = c.owner != address(0) ? c.owner : deployer;
        address feeRecipient = c.feeRecipient != address(0) ? c.feeRecipient : deployer;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 feeBps16 = uint16(c.feeBps); // <= 500, checked above
        d.launchpad = address(new DprkLaunchpad(d.pass, d.pancakeFactory, d.wbnb, feeRecipient, owner, v0, feeBps16));
        vm.stopBroadcast();
    }

    /// @dev PancakeSwap V2 factory and WBNB for `chainId`, and whether to deploy mocks instead.
    function _dex(uint256 chainId, address factory, address wbnb)
        internal
        pure
        returns (address, address, bool deployMocks)
    {
        if (chainId == BSC_MAINNET || chainId == BSC_TESTNET) {
            (address verifiedFactory, address verifiedWbnb) =
                chainId == BSC_MAINNET ? (BSC_FACTORY, BSC_WBNB) : (BSC_TESTNET_FACTORY, BSC_TESTNET_WBNB);
            require(
                (factory == address(0) || factory == verifiedFactory) && (wbnb == address(0) || wbnb == verifiedWbnb),
                "DeployDprkFun: PANCAKE_FACTORY/WBNB must be the verified addresses on 56/97"
            );
            return (verifiedFactory, verifiedWbnb, false);
        }
        if (factory != address(0) || wbnb != address(0)) {
            require(factory != address(0) && wbnb != address(0), "DeployDprkFun: set both PANCAKE_FACTORY and WBNB");
            return (factory, wbnb, false);
        }
        require(chainId == LOCAL_CHAIN, "DeployDprkFun: unknown chain, set PANCAKE_FACTORY and WBNB");
        return (address(0), address(0), true);
    }

    function _defaultV0(uint256 chainId) internal pure returns (uint256) {
        if (chainId == BSC_MAINNET) return 8 ether;
        if (chainId == BSC_TESTNET) return 0.5 ether;
        return 1 ether;
    }

    /// @dev Sanity bounds on V0. Other chains only get the launchpad's own [1e9, 1e25].
    function _v0Bounds(uint256 chainId) internal pure returns (uint256 minV0, uint256 maxV0) {
        if (chainId == BSC_MAINNET) return (1 ether, 100 ether);
        if (chainId == BSC_TESTNET) return (0.01 ether, 100 ether);
        return (1e9, 1e25);
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

    function _print(Deployment memory d) internal view {
        DprkLaunchpad launchpad = DprkLaunchpad(d.launchpad);
        console.log("");
        console.log("owner         ", launchpad.owner());
        console.log("feeRecipient  ", launchpad.feeRecipient());
        console.log("feeBps        ", uint256(launchpad.feeBps()));
        console.log("V0 (wei)      ", launchpad.initialVirtualBnbReserve());
        console.log("graduationBnb ", launchpad.graduationBnb());
        console.log("pancakeFactory", d.pancakeFactory);
        console.log("wbnb          ", d.wbnb);
        console.log("");
        console.log("# frontend/.env.local");
        console.log(string.concat("VITE_LAUNCHPAD_CHAIN_ID=", vm.toString(d.chainId)));
        if (d.chainId == LOCAL_CHAIN) {
            console.log("# local node: set this to the RPC you deployed to");
            console.log("VITE_LAUNCHPAD_RPC_URL=http://127.0.0.1:8545");
        }
        console.log(string.concat("VITE_DPRK_KIM_JONG_UN_ADDRESS=", vm.toString(d.kimJongUn)));
        console.log(string.concat("VITE_DPRK_PASS_ADDRESS=", vm.toString(d.pass)));
        console.log(string.concat("VITE_DPRK_LAUNCHPAD_ADDRESS=", vm.toString(d.launchpad)));
        console.log(string.concat("VITE_DPRK_DEPLOY_BLOCK=", vm.toString(d.deployBlock)));
    }
}
