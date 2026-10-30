// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployDprkFun} from "../../script/DeployDprkFun.s.sol";
import {DprkLaunchpad} from "../../src/launchpad/DprkLaunchpad.sol";
import {DprkPass} from "../../src/launchpad/DprkPass.sol";
import {MockWBNB} from "./mocks/MockWBNB.sol";
import {MockPancakeFactory} from "./mocks/MockPancakeV2.sol";

/// @notice Deploy-script rules per chain. Tests call `deploy(Config)` directly. That keeps them independent of
/// process-wide env vars, which forge shares across tests running in parallel.
contract DeployDprkFunTest is Test {
    address internal constant BSC_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address internal constant BSC_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant TESTNET_FACTORY = 0x6725F303b657a9451d8BA641348b6761A6CC7a17;
    address internal constant TESTNET_WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    uint256 internal constant OPBNB = 204; // a real chain that isn't 56/97

    DeployDprkFun internal script;
    address internal multisig = makeAddr("multisig");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        script = new DeployDprkFun();
    }

    function _cfg() internal pure returns (DeployDprkFun.Config memory c) {
        c.feeBps = 100;
        c.passName = "DPRK.FUN Not-Lazarus Pass";
        c.passSymbol = "NOTLAZ";
    }

    function _admin(DeployDprkFun.Config memory c) internal view returns (DeployDprkFun.Config memory) {
        c.owner = multisig;
        c.feeRecipient = treasury;
        return c;
    }

    /// @dev Stand-in code at the verified BSC addresses (the script only checks that code exists).
    function _etch(address factory, address wbnb) internal {
        vm.etch(factory, hex"00");
        vm.etch(wbnb, hex"00");
    }

    function _expect(string memory reason) internal {
        vm.expectRevert(bytes(string.concat("DeployDprkFun: ", reason)));
    }

    // ------------------------------------------------------------------------------------------- 31337

    function test_local_deploysMocksAndDefaultsAdminToDeployer() public {
        vm.chainId(31337);
        DeployDprkFun.Deployment memory d = script.deploy(_cfg());
        DprkLaunchpad pad = DprkLaunchpad(d.launchpad);
        assertEq(d.chainId, 31337);
        assertEq(pad.owner(), DEFAULT_SENDER);
        assertEq(pad.feeRecipient(), DEFAULT_SENDER);
        assertEq(pad.initialVirtualBnbReserve(), 1 ether);
        assertEq(pad.feeBps(), 100);
        assertEq(pad.pancakeFactory(), d.pancakeFactory);
        assertEq(pad.wbnb(), d.wbnb);
        assertEq(MockPancakeFactory(d.pancakeFactory).feeToSetter(), DEFAULT_SENDER);
        assertEq(MockWBNB(payable(d.wbnb)).symbol(), "WBNB");
        assertEq(DprkPass(d.pass).kimJongUn(), d.kimJongUn);
        assertEq(DprkPass(d.pass).symbol(), "NOTLAZ");
    }

    function test_local_explicitDexReplacesMocks() public {
        vm.chainId(31337);
        address wbnb = address(new MockWBNB());
        address factory = address(new MockPancakeFactory(address(this)));
        DeployDprkFun.Config memory c = _cfg();
        (c.pancakeFactory, c.wbnb) = (factory, wbnb);
        DeployDprkFun.Deployment memory d = script.deploy(c);
        assertEq(d.pancakeFactory, factory);
        assertEq(d.wbnb, wbnb);
        assertEq(DprkLaunchpad(d.launchpad).pancakeFactory(), factory);
    }

    function test_local_halfConfiguredDexReverts() public {
        vm.chainId(31337);
        DeployDprkFun.Config memory c = _cfg();
        c.wbnb = address(new MockWBNB());
        _expect("set both PANCAKE_FACTORY and WBNB");
        script.deploy(c);
    }

    function test_local_rejectsFeeAboveCapAndV0OutsideLaunchpadBounds() public {
        vm.chainId(31337);
        DeployDprkFun.Config memory c = _cfg();
        c.feeBps = 501;
        _expect("FEE_BPS > 500");
        script.deploy(c);

        c = _cfg();
        c.initialVirtualBnb = 1e25 + 1;
        _expect("INITIAL_VIRTUAL_BNB out of range for this chain");
        script.deploy(c);
        c.initialVirtualBnb = 1e9 - 1;
        _expect("INITIAL_VIRTUAL_BNB out of range for this chain");
        script.deploy(c);
    }

    function test_local_reusesRegistryAndChecksItsCode() public {
        vm.chainId(31337);
        DeployDprkFun.Deployment memory first = script.deploy(_cfg());
        DeployDprkFun.Config memory c = _cfg();
        c.kimJongUn = first.kimJongUn;
        DeployDprkFun.Deployment memory second = script.deploy(c);
        assertEq(second.kimJongUn, first.kimJongUn);
        assertEq(DprkPass(second.pass).kimJongUn(), first.kimJongUn);

        c.kimJongUn = makeAddr("eoa");
        _expect("KIM_JONG_UN_ADDRESS has no code");
        script.deploy(c);
    }

    // ------------------------------------------------------------------------------------------- other chains

    /// Review L-2: any chain id other than 56/97 used to get a deployer-controlled mock DEX, silently.
    function test_unknownChain_neverDeploysMocks() public {
        vm.chainId(OPBNB);
        _expect("unknown chain, set PANCAKE_FACTORY and WBNB");
        script.deploy(_admin(_cfg()));
    }

    function test_unknownChain_requiresOwnerAndFeeRecipient() public {
        vm.chainId(OPBNB);
        DeployDprkFun.Config memory c = _cfg();
        (c.pancakeFactory, c.wbnb) = (address(new MockPancakeFactory(address(this))), address(new MockWBNB()));
        _expect("OWNER is required on this chain");
        script.deploy(c);
        c.owner = multisig;
        _expect("FEE_RECIPIENT is required on this chain");
        script.deploy(c);
    }

    function test_unknownChain_requiresCodeAtBothDexAddresses() public {
        vm.chainId(OPBNB);
        DeployDprkFun.Config memory c = _admin(_cfg());
        (c.pancakeFactory, c.wbnb) = (makeAddr("factoryEoa"), address(new MockWBNB()));
        _expect("PANCAKE_FACTORY/WBNB have no code");
        script.deploy(c);
        (c.pancakeFactory, c.wbnb) = (address(new MockPancakeFactory(address(this))), makeAddr("wbnbEoa"));
        _expect("PANCAKE_FACTORY/WBNB have no code");
        script.deploy(c);
        c.wbnb = address(0);
        _expect("set both PANCAKE_FACTORY and WBNB");
        script.deploy(c);
    }

    function test_unknownChain_explicitConfigDeploys() public {
        vm.chainId(OPBNB);
        address factory = address(new MockPancakeFactory(address(this)));
        address wbnb = address(new MockWBNB());
        DeployDprkFun.Config memory c = _admin(_cfg());
        (c.pancakeFactory, c.wbnb) = (factory, wbnb);
        DeployDprkFun.Deployment memory d = script.deploy(c);
        DprkLaunchpad pad = DprkLaunchpad(d.launchpad);
        assertEq(d.pancakeFactory, factory); // exactly what was passed: no mock was deployed by the script
        assertEq(d.wbnb, wbnb);
        assertEq(pad.owner(), multisig);
        assertEq(pad.feeRecipient(), treasury);
        assertEq(pad.initialVirtualBnbReserve(), 1 ether);
    }

    // ------------------------------------------------------------------------------------------- 56

    function test_bscMainnet_requiresExplicitOwnerAndFeeRecipient() public {
        vm.chainId(56);
        _etch(BSC_FACTORY, BSC_WBNB);
        DeployDprkFun.Config memory c = _cfg();
        _expect("OWNER is required on this chain");
        script.deploy(c);
        c.owner = multisig;
        _expect("FEE_RECIPIENT is required on this chain");
        script.deploy(c);
        c.feeRecipient = treasury;
        DprkLaunchpad pad = DprkLaunchpad(script.deploy(c).launchpad);
        assertEq(pad.owner(), multisig);
        assertEq(pad.feeRecipient(), treasury);
        assertEq(pad.pancakeFactory(), BSC_FACTORY);
        assertEq(pad.wbnb(), BSC_WBNB);
        assertEq(pad.initialVirtualBnbReserve(), 8 ether);
        assertEq(pad.graduationBnb(), 24 ether + 1);
    }

    function test_bscMainnet_v0SanityBounds() public {
        vm.chainId(56);
        _etch(BSC_FACTORY, BSC_WBNB);
        DeployDprkFun.Config memory c = _admin(_cfg());
        c.initialVirtualBnb = 1 ether - 1;
        _expect("INITIAL_VIRTUAL_BNB out of range for this chain");
        script.deploy(c);
        c.initialVirtualBnb = 100 ether + 1;
        _expect("INITIAL_VIRTUAL_BNB out of range for this chain");
        script.deploy(c);
        c.initialVirtualBnb = 1 ether;
        assertEq(DprkLaunchpad(script.deploy(c).launchpad).initialVirtualBnbReserve(), 1 ether);
        c.initialVirtualBnb = 100 ether;
        assertEq(DprkLaunchpad(script.deploy(c).launchpad).initialVirtualBnbReserve(), 100 ether);
    }

    /// Review PoC: chain 56 without a fork has no PancakeSwap code, and the script stops before broadcasting.
    function test_bscMainnet_withoutForkReverts() public {
        vm.chainId(56);
        _expect("PANCAKE_FACTORY/WBNB have no code");
        script.deploy(_admin(_cfg()));
    }

    function test_bscMainnet_dexOverrideMustMatchVerifiedAddresses() public {
        vm.chainId(56);
        _etch(BSC_FACTORY, BSC_WBNB);
        DeployDprkFun.Config memory c = _admin(_cfg());
        c.pancakeFactory = address(new MockPancakeFactory(address(this)));
        _expect("PANCAKE_FACTORY/WBNB must be the verified addresses on 56/97");
        script.deploy(c);
        c.pancakeFactory = address(0);
        c.wbnb = TESTNET_WBNB; // testnet WBNB on mainnet: wrong
        _expect("PANCAKE_FACTORY/WBNB must be the verified addresses on 56/97");
        script.deploy(c);
        (c.pancakeFactory, c.wbnb) = (BSC_FACTORY, BSC_WBNB); // repeating the verified addresses is fine
        assertEq(DprkLaunchpad(script.deploy(c).launchpad).pancakeFactory(), BSC_FACTORY);
    }

    // ------------------------------------------------------------------------------------------- 97

    function test_bscTestnet_adminDefaultsAndV0Bounds() public {
        vm.chainId(97);
        _etch(TESTNET_FACTORY, TESTNET_WBNB);
        DeployDprkFun.Config memory c = _cfg();
        DprkLaunchpad pad = DprkLaunchpad(script.deploy(c).launchpad);
        assertEq(pad.owner(), DEFAULT_SENDER);
        assertEq(pad.feeRecipient(), DEFAULT_SENDER);
        assertEq(pad.pancakeFactory(), TESTNET_FACTORY);
        assertEq(pad.wbnb(), TESTNET_WBNB);
        assertEq(pad.initialVirtualBnbReserve(), 0.5 ether);

        c.initialVirtualBnb = 0.01 ether - 1;
        _expect("INITIAL_VIRTUAL_BNB out of range for this chain");
        script.deploy(c);
        c.initialVirtualBnb = 0.01 ether;
        assertEq(DprkLaunchpad(script.deploy(c).launchpad).initialVirtualBnbReserve(), 0.01 ether);
        c.initialVirtualBnb = 100 ether + 1;
        _expect("INITIAL_VIRTUAL_BNB out of range for this chain");
        script.deploy(c);
    }

    // ------------------------------------------------------------------------------------------- env

    /// The only test that touches process env: it pins the variable names that operators and the E2E run use.
    function test_configFromEnv_readsEveryVariable() public {
        vm.setEnv("KIM_JONG_UN_ADDRESS", vm.toString(address(0x1111)));
        vm.setEnv("PANCAKE_FACTORY", vm.toString(address(0x2222)));
        vm.setEnv("WBNB", vm.toString(address(0x3333)));
        vm.setEnv("OWNER", vm.toString(multisig));
        vm.setEnv("FEE_RECIPIENT", vm.toString(treasury));
        vm.setEnv("FEE_BPS", "250");
        vm.setEnv("INITIAL_VIRTUAL_BNB", "2000000000000000000");
        vm.setEnv("PASS_NAME", "Env Pass");
        vm.setEnv("PASS_SYMBOL", "ENV");
        DeployDprkFun.Config memory c = script.configFromEnv();
        assertEq(c.kimJongUn, address(0x1111));
        assertEq(c.pancakeFactory, address(0x2222));
        assertEq(c.wbnb, address(0x3333));
        assertEq(c.owner, multisig);
        assertEq(c.feeRecipient, treasury);
        assertEq(c.feeBps, 250);
        assertEq(c.initialVirtualBnb, 2 ether);
        assertEq(c.passName, "Env Pass");
        assertEq(c.passSymbol, "ENV");
    }
}
