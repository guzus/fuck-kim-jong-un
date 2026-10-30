// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DprkLaunchpad} from "../../src/launchpad/DprkLaunchpad.sol";
import {DprkToken} from "../../src/launchpad/DprkToken.sol";
import {IDprkLaunchpad} from "../../src/launchpad/interfaces/IDprkLaunchpad.sol";
import {LaunchpadTestBase} from "./utils/LaunchpadTestBase.sol";

/// @notice Fuzzes the curve math across V0, fee, curve position, and trade sizes.
contract DprkLaunchpadFuzzTest is LaunchpadTestBase {
    DprkLaunchpad internal pad;
    address internal token;

    /// @dev Fresh launchpad with fuzzed parameters, a token, and an optional pre-buy that never completes it.
    function _setup(uint256 v0, uint256 feeBps, uint256 preBuyBps) internal returns (uint256 v0_, uint16 fee_) {
        v0_ = bound(v0, 1e9, 1e25);
        fee_ = uint16(bound(feeBps, 0, 500));
        pad = _deployLaunchpad(v0_, fee_);
        vm.deal(alice, type(uint128).max);
        vm.deal(bob, type(uint128).max);
        vm.deal(carol, type(uint128).max);
        token = _create(pad, alice, 0);
        preBuyBps = bound(preBuyBps, 0, 9_999);
        uint256 pre = _grossToComplete(pad, token) * preBuyBps / 10_000;
        if (pre != 0 && _quoteOut(pre) != 0) _buy(pad, carol, token, pre);
    }

    function _quoteOut(uint256 value) internal view returns (uint256 out) {
        (out,,,) = pad.quoteBuy(token, value);
    }

    function _st() internal view returns (IDprkLaunchpad.TokenState memory) {
        return pad.getTokenState(token);
    }

    // ------------------------------------------------------------------------------------------- buys

    function testFuzz_buyMatchesQuoteAndRoundsForPool(uint256 v0, uint256 fee, uint256 pre, uint256 value) public {
        (, uint16 feeBps) = _setup(v0, fee, pre);
        IDprkLaunchpad.TokenState memory before = _st();
        uint256 gross = _grossToComplete(pad, token);
        value = bound(value, 1, gross * 2);
        (uint256 quoted, uint256 qFee, uint256 accepted, uint256 refund) = pad.quoteBuy(token, value);
        vm.assume(quoted != 0);

        assertLe(accepted, value, "accepted above msg.value");
        assertEq(accepted + refund, value);
        assertEq(qFee, Math.mulDiv(accepted, feeBps, 10_000, Math.Rounding.Ceil), "fee is ceil(accepted * bps)");

        uint256 bobBnb = bob.balance;
        uint256 out = _buy(pad, bob, token, value);
        IDprkLaunchpad.TokenState memory s = _st();

        assertEq(out, quoted);
        assertEq(bob.balance, bobBnb - accepted);
        assertEq(s.realBnbReserve, before.realBnbReserve + accepted - qFee);
        assertGe(_k(s), _k(before), "k decreased");
        if (value >= gross) {
            assertEq(out, before.realTokenReserve, "completing buy must take exactly the remainder");
            assertTrue(s.graduated);
        } else {
            assertLt(out, before.realTokenReserve, "non-completing buy reached the remainder");
            assertFalse(s.graduated);
            // Output rounds down: never more than the exact constant-product amount.
            uint256 net = accepted - qFee;
            assertLe(out * (before.virtualBnbReserve + net), before.virtualTokenReserve * net);
        }
    }

    /// @notice Premise 4: the ceil-rounded completing input never exceeds msg.value, and it is a sharp threshold.
    function testFuzz_completingThresholdIsSharp(uint256 v0, uint256 fee, uint256 pre, uint256 extra) public {
        _setup(v0, fee, pre);
        uint256 remaining = _st().realTokenReserve;
        uint256 gross = _grossToComplete(pad, token);
        extra = bound(extra, 0, 1e30);

        (uint256 below,, uint256 acceptedBelow, uint256 refundBelow) = pad.quoteBuy(token, gross - 1);
        assertLt(below, remaining);
        assertEq(acceptedBelow, gross - 1);
        assertEq(refundBelow, 0);

        (uint256 at,, uint256 acceptedAt, uint256 refundAt) = pad.quoteBuy(token, gross + extra);
        assertEq(at, remaining);
        assertEq(acceptedAt, gross);
        assertEq(refundAt, extra);
    }

    function testFuzz_splitBuyNeverBeatsSingleBuy(uint256 v0, uint256 fee, uint256 pre, uint256 a, uint256 b) public {
        _setup(v0, fee, pre);
        uint256 gross = _grossToComplete(pad, token);
        a = bound(a, 1, gross / 2);
        b = bound(b, 1, gross / 2);
        uint256 single = _quoteOut(a + b);
        vm.assume(single != 0 && a + b < gross);

        uint256 snap = vm.snapshotState();
        uint256 split;
        if (_quoteOut(a) != 0) split += _buy(pad, bob, token, a);
        if (_quoteOut(b) != 0) split += _buy(pad, bob, token, b);
        vm.revertToState(snap);
        assertLe(split, single);
    }

    // ------------------------------------------------------------------------------------------- sells

    function testFuzz_roundTripNeverProfits(uint256 v0, uint256 fee, uint256 pre, uint256 value, uint256 sellBps)
        public
    {
        _setup(v0, fee, pre);
        value = bound(value, 1, _grossToComplete(pad, token) - 1);
        vm.assume(_quoteOut(value) != 0);
        uint256 got = _buy(pad, bob, token, value);
        uint256 amount = bound(sellBps, 1, 10_000) * got / 10_000;
        (uint256 quoted, uint256 qFee) = pad.quoteSell(token, amount);
        vm.assume(quoted != 0);
        uint256 back = _sell(pad, bob, token, amount);
        assertEq(back, quoted);
        assertLe(back + qFee, value, "buy-then-sell returned more than was paid in");
    }

    function testFuzz_sellMatchesQuoteAndKNeverDecreases(uint256 v0, uint256 fee, uint256 pre, uint256 bps) public {
        (, uint16 feeBps) = _setup(v0, fee, pre);
        uint256 held = DprkToken(token).balanceOf(carol);
        vm.assume(held != 0);
        uint256 amount = bound(bps, 1, 10_000) * held / 10_000;
        IDprkLaunchpad.TokenState memory before = _st();
        (uint256 quoted, uint256 qFee) = pad.quoteSell(token, amount);
        vm.assume(quoted != 0);
        uint256 gross = quoted + qFee;
        assertEq(gross, Math.mulDiv(before.virtualBnbReserve, amount, before.virtualTokenReserve + amount));
        assertEq(qFee, Math.mulDiv(gross, feeBps, 10_000, Math.Rounding.Ceil));
        assertEq(_sell(pad, carol, token, amount), quoted);
        IDprkLaunchpad.TokenState memory s = _st();
        assertGe(_k(s), _k(before), "k decreased");
        assertEq(s.realBnbReserve, before.realBnbReserve - gross);
    }

    /// @notice Every holder can always exit: selling all circulating tokens, in any order, is always payable.
    function testFuzz_everyoneCanAlwaysSellOut(uint256 v0, uint256 fee, uint256 b1, uint256 b2, uint256 b3, bool order)
        public
    {
        _setup(v0, fee, 0);
        uint256 gross = _grossToComplete(pad, token);
        address[3] memory who = [alice, bob, carol];
        uint256[3] memory amounts = [bound(b1, 0, gross / 3), bound(b2, 0, gross / 3), bound(b3, 0, gross / 3)];
        for (uint256 i; i < 3; ++i) {
            if (amounts[i] != 0 && _quoteOut(amounts[i]) != 0) _buy(pad, who[i], token, amounts[i]);
        }
        IDprkLaunchpad.TokenState memory s = _st();
        // Selling every circulating token at once is quotable from real reserves.
        uint256 circulating = S - s.realTokenReserve;
        (uint256 all, uint256 allFee) = pad.quoteSell(token, circulating);
        assertLe(all + allFee, s.realBnbReserve);

        for (uint256 j; j < 3; ++j) {
            address seller = who[order ? j : 2 - j];
            uint256 bal = DprkToken(token).balanceOf(seller);
            if (bal == 0) continue;
            (uint256 q,) = pad.quoteSell(token, bal);
            if (q == 0) continue; // pure dust
            _sell(pad, seller, token, bal);
        }
        s = _st();
        assertGe(address(pad).balance, s.realBnbReserve + pad.accruedFees());
        assertGe(s.virtualBnbReserve, pad.initialVirtualBnbReserve());
    }

    // ------------------------------------------------------------------------------------------- graduation

    function testFuzz_graduationListsAtOrAboveCurvePrice(uint256 v0, uint256 fee, uint256 pre, uint256 donation)
        public
    {
        _setup(v0, fee, pre);
        donation = bound(donation, 0, 1000 ether);
        if (donation != 0) {
            address pair = factory.getPair(token, address(wbnb));
            if (pair == address(0)) pair = factory.createPair(token, address(wbnb));
            vm.deal(mallory, donation);
            vm.startPrank(mallory);
            wbnb.deposit{value: donation}();
            wbnb.transfer(pair, donation);
            vm.stopPrank();
        }
        _buy(pad, bob, token, _grossToComplete(pad, token));
        IDprkLaunchpad.TokenState memory s = _st();
        assertTrue(s.graduated);
        assertGe(s.realBnbReserve, pad.graduationBnb());
        (uint256 rb, uint256 rt) = _pairReserves(s.pair, token);
        assertEq(rt, L);
        assertEq(rb, s.realBnbReserve + donation);
        assertGe(rb * s.virtualTokenReserve, s.virtualBnbReserve * rt, "pool price below curve price");
        assertEq(address(pad).balance, pad.accruedFees());
    }
}
