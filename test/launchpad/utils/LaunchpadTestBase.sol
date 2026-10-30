// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KimJongUn} from "../../../src/KimJongUn.sol";
import {DprkPass} from "../../../src/launchpad/DprkPass.sol";
import {DprkLaunchpad} from "../../../src/launchpad/DprkLaunchpad.sol";
import {DprkToken} from "../../../src/launchpad/DprkToken.sol";
import {IDprkLaunchpad} from "../../../src/launchpad/interfaces/IDprkLaunchpad.sol";
import {IPancakeV2Pair} from "../../../src/launchpad/interfaces/IPancakeV2.sol";
import {MockWBNB} from "../mocks/MockWBNB.sol";
import {MockPancakeFactory} from "../mocks/MockPancakeV2.sol";

/// @notice Shared local deployment: KimJongUn registry, pass, mock WBNB + PancakeSwap V2, launchpad.
abstract contract LaunchpadTestBase is Test {
    uint256 internal constant V0 = 1 ether;
    uint16 internal constant FEE_BPS = 100;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant S = 800_000_000e18;
    uint256 internal constant L = 200_000_000e18;
    uint256 internal constant Y0 = S * S / (S - L);
    uint256 internal constant Y_END = Y0 - S;

    KimJongUn internal kimJongUn;
    DprkPass internal pass;
    MockWBNB internal wbnb;
    MockPancakeFactory internal factory;
    DprkLaunchpad internal launchpad;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    /// @dev Never certified.
    address internal mallory = makeAddr("mallory");

    string internal constant NAME = "Kim Pig";
    string internal constant SYMBOL = "KPIG";
    string internal constant METADATA = '{"description":"oink","image":"ipfs://pig"}';

    function setUp() public virtual {
        kimJongUn = new KimJongUn();
        pass = new DprkPass(address(kimJongUn), "DPRK.FUN Not-Lazarus Pass", "NOTLAZ");
        wbnb = new MockWBNB();
        factory = new MockPancakeFactory(address(this));
        launchpad = _deployLaunchpad(V0, FEE_BPS);

        _certify(alice);
        _certify(bob);
        _certify(carol);
        vm.deal(alice, 10_000 ether);
        vm.deal(bob, 10_000 ether);
        vm.deal(carol, 10_000 ether);
        vm.deal(mallory, 10_000 ether);
    }

    function _deployLaunchpad(uint256 v0, uint16 feeBps) internal returns (DprkLaunchpad) {
        return new DprkLaunchpad(address(pass), address(factory), address(wbnb), feeRecipient, owner, v0, feeBps);
    }

    function _certify(address who) internal {
        vm.startPrank(who);
        kimJongUn.pig();
        kimJongUn.fuck();
        pass.claim();
        vm.stopPrank();
    }

    function _create(address creator) internal returns (address token) {
        return _create(launchpad, creator, 0);
    }

    function _create(DprkLaunchpad pad, address creator, uint256 value) internal returns (address token) {
        vm.prank(creator);
        (token,) = pad.createToken{value: value}(NAME, SYMBOL, METADATA, 0, block.timestamp);
    }

    function _buy(address buyer, address token, uint256 value) internal returns (uint256) {
        return _buy(launchpad, buyer, token, value);
    }

    function _buy(DprkLaunchpad pad, address buyer, address token, uint256 value) internal returns (uint256) {
        vm.prank(buyer);
        return pad.buy{value: value}(token, 0, block.timestamp);
    }

    function _sell(address seller, address token, uint256 amount) internal returns (uint256) {
        return _sell(launchpad, seller, token, amount);
    }

    function _sell(DprkLaunchpad pad, address seller, address token, uint256 amount) internal returns (uint256 out) {
        vm.startPrank(seller);
        DprkToken(token).approve(address(pad), amount);
        out = pad.sell(token, amount, 0, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Gross BNB (fee included) that buys the whole remaining curve right now.
    function _grossToComplete(address token) internal view returns (uint256 accepted) {
        return _grossToComplete(launchpad, token);
    }

    function _grossToComplete(DprkLaunchpad pad, address token) internal view returns (uint256 accepted) {
        (,, accepted,) = pad.quoteBuy(token, type(uint256).max);
    }

    function _state(address token) internal view returns (IDprkLaunchpad.TokenState memory) {
        return launchpad.getTokenState(token);
    }

    function _k(IDprkLaunchpad.TokenState memory s) internal pure returns (uint256) {
        return s.virtualBnbReserve * s.virtualTokenReserve;
    }

    /// @dev Pair reserves as (wbnb, token).
    function _pairReserves(address pair, address token)
        internal
        view
        returns (uint256 bnbReserve, uint256 tokenReserve)
    {
        (uint112 r0, uint112 r1,) = IPancakeV2Pair(pair).getReserves();
        (bnbReserve, tokenReserve) =
            IPancakeV2Pair(pair).token0() == token ? (uint256(r1), uint256(r0)) : (uint256(r0), uint256(r1));
    }
}
