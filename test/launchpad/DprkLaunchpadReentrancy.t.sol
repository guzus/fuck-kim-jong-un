// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {KimJongUn} from "../../src/KimJongUn.sol";
import {DprkPass} from "../../src/launchpad/DprkPass.sol";
import {DprkLaunchpad} from "../../src/launchpad/DprkLaunchpad.sol";
import {DprkToken} from "../../src/launchpad/DprkToken.sol";
import {IDprkLaunchpad} from "../../src/launchpad/interfaces/IDprkLaunchpad.sol";
import {LaunchpadTestBase} from "./utils/LaunchpadTestBase.sol";

/// @notice A certified contract that tries to re-enter the launchpad whenever it receives BNB.
contract Reentrant {
    enum Attack {
        None,
        Buy,
        Sell,
        Create,
        ClaimFees
    }

    DprkLaunchpad internal immutable launchpad;
    address public token;
    Attack public attack;
    bool public bubble;
    bytes public lastError;
    uint256 public calls;
    /// @dev State observed from inside the callback (read-only reentrancy check).
    uint256 public seenRealTokenReserve;
    uint256 public seenRealBnbReserve;

    constructor(DprkLaunchpad launchpad_) {
        launchpad = launchpad_;
    }

    function certify(KimJongUn kim, DprkPass pass) external {
        kim.pig();
        kim.fuck();
        pass.claim();
    }

    function arm(address token_, Attack attack_, bool bubble_) external {
        token = token_;
        attack = attack_;
        bubble = bubble_;
    }

    function buy(address token_, uint256 value) external returns (uint256) {
        return launchpad.buy{value: value}(token_, 0, block.timestamp);
    }

    function sell(address token_, uint256 amount) external returns (uint256) {
        DprkToken(token_).approve(address(launchpad), type(uint256).max);
        return launchpad.sell(token_, amount, 0, block.timestamp);
    }

    receive() external payable {
        if (attack == Attack.None || calls != 0) return;
        calls++;
        IDprkLaunchpad.TokenState memory s = launchpad.getTokenState(token);
        seenRealTokenReserve = s.realTokenReserve;
        seenRealBnbReserve = s.realBnbReserve;

        bool ok;
        bytes memory err;
        if (attack == Attack.Buy) {
            (ok, err) = address(launchpad).call{value: 0.01 ether}(
                abi.encodeCall(DprkLaunchpad.buy, (token, 0, block.timestamp))
            );
        } else if (attack == Attack.Sell) {
            uint256 bal = DprkToken(token).balanceOf(address(this));
            (ok, err) = address(launchpad).call(abi.encodeCall(DprkLaunchpad.sell, (token, bal, 0, block.timestamp)));
        } else if (attack == Attack.Create) {
            (ok, err) = address(launchpad).call{value: 0.01 ether}(
                abi.encodeCall(DprkLaunchpad.createToken, ("Again", "AGN", "", 0, block.timestamp))
            );
        } else {
            (ok, err) = address(launchpad).call(abi.encodeCall(DprkLaunchpad.claimFees, ()));
        }
        lastError = err;
        if (ok) revert("reentry succeeded");
        if (bubble) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
    }
}

contract DprkLaunchpadReentrancyTest is LaunchpadTestBase {
    Reentrant internal attacker;
    bytes internal REENTRANT = abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);

    function setUp() public override {
        super.setUp();
        attacker = new Reentrant(launchpad);
        attacker.certify(kimJongUn, pass);
        vm.deal(address(attacker), 100 ether);
    }

    function _completingBuyWithRefund(address token) internal returns (uint256) {
        return attacker.buy(token, _grossToComplete(token) + 1 ether);
    }

    function test_refund_reentryIntoBuyBlocked() public {
        address token = _create(alice);
        attacker.arm(token, Reentrant.Attack.Buy, false);
        _completingBuyWithRefund(token);
        assertEq(attacker.lastError(), REENTRANT);
        assertTrue(_state(token).graduated);
        // The refund callback runs after graduation finished: it observed the final state.
        assertEq(attacker.seenRealTokenReserve(), 0);
    }

    function test_refund_reentryIntoSellBlocked() public {
        address token = _create(alice);
        attacker.buy(token, 0.5 ether); // hold some tokens first
        attacker.arm(token, Reentrant.Attack.Sell, false);
        _completingBuyWithRefund(token);
        assertEq(attacker.lastError(), REENTRANT);
    }

    function test_refund_reentryIntoCreateBlocked() public {
        address token = _create(alice);
        attacker.arm(token, Reentrant.Attack.Create, false);
        _completingBuyWithRefund(token);
        assertEq(attacker.lastError(), REENTRANT);
        assertEq(launchpad.tokenCount(), 1);
    }

    function test_refund_reentryIntoClaimFeesBlocked() public {
        address token = _create(alice);
        _buy(bob, token, 1 ether);
        attacker.arm(token, Reentrant.Attack.ClaimFees, false);
        _completingBuyWithRefund(token);
        assertEq(attacker.lastError(), REENTRANT);
        assertGt(launchpad.accruedFees(), 0);
    }

    function test_refund_bubblingAttackerRevertsWholeBuy() public {
        address token = _create(alice);
        attacker.arm(token, Reentrant.Attack.Buy, true);
        uint256 gross = _grossToComplete(token);
        vm.expectRevert(IDprkLaunchpad.BnbTransferFailed.selector);
        attacker.buy(token, gross + 1 ether);
        // Nothing changed; anyone else can still complete the curve.
        assertFalse(_state(token).graduated);
        _buy(bob, token, gross + 1 ether);
        assertTrue(_state(token).graduated);
    }

    function test_sellPayout_doubleSellBlockedAndStateAlreadyUpdated() public {
        address token = _create(alice);
        uint256 bought = attacker.buy(token, 1 ether);
        attacker.arm(token, Reentrant.Attack.Sell, false);
        uint256 out = attacker.sell(token, bought / 2);
        assertGt(out, 0);
        assertEq(attacker.lastError(), REENTRANT);
        assertEq(DprkToken(token).balanceOf(address(attacker)), bought - bought / 2);

        // Checks-effects-interactions: the callback already saw the post-sell reserves.
        IDprkLaunchpad.TokenState memory s = _state(token);
        assertEq(attacker.seenRealTokenReserve(), s.realTokenReserve);
        assertEq(attacker.seenRealBnbReserve(), s.realBnbReserve);
        assertEq(address(launchpad).balance, s.realBnbReserve + launchpad.accruedFees());
    }

    function test_sellPayout_reentryIntoBuyBlocked() public {
        address token = _create(alice);
        uint256 bought = attacker.buy(token, 1 ether);
        attacker.arm(token, Reentrant.Attack.Buy, false);
        attacker.sell(token, bought);
        assertEq(attacker.lastError(), REENTRANT);
    }

    function test_feeRecipient_reentryBlocked() public {
        address token = _create(alice);
        _buy(bob, token, 1 ether);
        vm.prank(owner);
        launchpad.setFeeRecipient(address(attacker));

        attacker.arm(token, Reentrant.Attack.ClaimFees, false);
        uint256 fees = launchpad.claimFees();
        assertEq(attacker.lastError(), REENTRANT);
        assertEq(launchpad.accruedFees(), 0);
        assertEq(address(launchpad).balance, _state(token).realBnbReserve);
        assertGt(fees, 0);
    }
}
