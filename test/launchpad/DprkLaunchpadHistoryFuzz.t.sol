// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Ported from the independent review's regression suite (ReviewAccountingFuzz).

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DprkLaunchpad} from "../../src/launchpad/DprkLaunchpad.sol";
import {DprkToken} from "../../src/launchpad/DprkToken.sol";
import {IDprkLaunchpad} from "../../src/launchpad/interfaces/IDprkLaunchpad.sol";
import {LaunchpadTestBase} from "./utils/LaunchpadTestBase.sol";

/// @notice Accounting and rounding from states reached through random multi-party histories. Rounding has
/// accumulated there and k > k0, unlike the single pre-buy in DprkLaunchpadFuzz.
contract DprkLaunchpadHistoryFuzzTest is LaunchpadTestBase {
    DprkLaunchpad internal pad;
    address internal dave = makeAddr("dave");

    function _deploy(uint256 v0Seed, uint256 feeSeed) internal {
        pad = _deployLaunchpad(bound(v0Seed, 1e9, 1e25), uint16(bound(feeSeed, 0, 500)));
        _certify(dave);
        vm.deal(alice, type(uint128).max);
        vm.deal(bob, type(uint128).max);
        vm.deal(carol, type(uint128).max);
        vm.deal(dave, type(uint128).max);
    }

    function _newToken() internal returns (address token) {
        vm.prank(alice);
        (token,) = pad.createToken(NAME, SYMBOL, METADATA, 0, block.timestamp);
    }

    function _gross(address token) internal view returns (uint256 g) {
        (,, g,) = pad.quoteBuy(token, type(uint256).max);
    }

    /// @dev Non-completing buy with a log-uniform size. Skips dust.
    function _tryBuy(address who, address token, uint256 seed) internal returns (uint256 out) {
        uint256 g = _gross(token);
        if (g < 2) return 0;
        uint256 cap = Math.max(1, (g - 1) >> (seed % 48));
        uint256 v = bound(seed >> 8, 1, cap);
        (uint256 q,,,) = pad.quoteBuy(token, v);
        if (q == 0) return 0;
        vm.prank(who);
        out = pad.buy{value: v}(token, q, block.timestamp);
    }

    /// @dev Sells a fraction of `who`'s balance. Skips dust.
    function _trySell(address who, address token, uint256 seed) internal returns (uint256 out) {
        uint256 bal = DprkToken(token).balanceOf(who);
        uint256 amt = seed % 4 == 0 ? bal : bal * bound(seed >> 2, 1, 10_000) / 10_000;
        if (amt == 0) return 0;
        (uint256 q,) = pad.quoteSell(token, amt);
        if (q == 0) return 0;
        vm.startPrank(who);
        DprkToken(token).approve(address(pad), amt);
        out = pad.sell(token, amt, q, block.timestamp);
        vm.stopPrank();
    }

    function _history(address token, uint256[10] memory ops) internal {
        for (uint256 i; i < ops.length; ++i) {
            address who = ops[i] % 3 == 0 ? bob : ops[i] % 3 == 1 ? carol : alice;
            if ((ops[i] >> 2) % 3 != 0) _tryBuy(who, token, ops[i] >> 4);
            else _trySell(who, token, ops[i] >> 4);
            _assertCurveHealthy(token);
        }
    }

    function _assertCurveHealthy(address token) internal view {
        IDprkLaunchpad.TokenState memory s = pad.getTokenState(token);
        if (s.graduated) return;
        uint256 v0 = pad.initialVirtualBnbReserve();
        assertGe(s.virtualBnbReserve * s.virtualTokenReserve, v0 * Y0, "k below k0");
        // Every circulating token is sellable from this curve's own BNB.
        (uint256 out, uint256 fee) = pad.quoteSell(token, S - s.realTokenReserve);
        assertLe(out + fee, s.realBnbReserve, "circulating supply not fully backed");
    }

    /// A trader alone on a curve, starting from any history, can't end with more BNB than it started with after
    /// exiting. (k never decreases and fees leave the curve, so returning to the same token reserve leaves at
    /// least as much BNB in the curve.)
    function testFuzz_soloTraderNeverExtracts(
        uint256 v0Seed,
        uint256 feeSeed,
        uint256[10] memory history,
        uint256[10] memory ops
    ) public {
        _deploy(v0Seed, feeSeed);
        address token = _newToken();
        _history(token, history);

        uint256 start = dave.balance;
        uint256 kStart;
        {
            IDprkLaunchpad.TokenState memory s0 = pad.getTokenState(token);
            kStart = s0.virtualBnbReserve * s0.virtualTokenReserve;
        }
        for (uint256 i; i < ops.length; ++i) {
            if (ops[i] % 2 == 0) _tryBuy(dave, token, ops[i] >> 1);
            else _trySell(dave, token, ops[i] >> 1);
            _assertCurveHealthy(token);
        }
        _trySell(dave, token, 0); // exit everything (seed % 4 == 0 sells the whole balance)

        assertLe(dave.balance, start, "solo trader extracted BNB");
        IDprkLaunchpad.TokenState memory s = pad.getTokenState(token);
        assertGe(s.virtualBnbReserve * s.virtualTokenReserve, kStart, "k decreased");
        assertEq(address(pad).balance, s.realBnbReserve + pad.accruedFees(), "solvency");
    }

    /// The completing buy after an arbitrary history: charges exactly grossRequired (<= msg.value), delivers
    /// exactly the remainder, refunds the rest, graduates, and lists at or above the final curve price.
    function testFuzz_completingBuyAfterRandomHistory(
        uint256 v0Seed,
        uint256 feeSeed,
        uint256[10] memory history,
        uint256 extra
    ) public {
        _deploy(v0Seed, feeSeed);
        address token = _newToken();
        _history(token, history);

        IDprkLaunchpad.TokenState memory before = pad.getTokenState(token);
        uint256 g = _gross(token);
        extra = bound(extra, 0, 1e30);

        // Sharp threshold: one wei less never completes and is never charged more than sent.
        (uint256 below,, uint256 acceptedBelow, uint256 refundBelow) = pad.quoteBuy(token, g - 1);
        assertLt(below, before.realTokenReserve);
        assertEq(acceptedBelow + refundBelow, g - 1);

        uint256 fees0 = pad.accruedFees();
        uint256 bal0 = dave.balance;
        vm.prank(dave);
        uint256 out = pad.buy{value: g + extra}(token, before.realTokenReserve, block.timestamp);

        assertEq(out, before.realTokenReserve, "completing buy must deliver exactly the remainder");
        assertEq(bal0 - dave.balance, g, "charged != grossRequired");
        IDprkLaunchpad.TokenState memory s = pad.getTokenState(token);
        assertTrue(s.graduated);
        assertGe(s.realBnbReserve, pad.graduationBnb());
        assertEq(address(pad).balance, pad.accruedFees(), "curve BNB left behind");
        assertEq(pad.accruedFees() - fees0, Math.mulDiv(g, pad.feeBps(), 10_000, Math.Rounding.Ceil));
        assertGe(
            s.virtualBnbReserve * s.virtualTokenReserve,
            before.virtualBnbReserve * before.virtualTokenReserve,
            "k decreased"
        );
        (uint256 rb, uint256 rt) = _pairReserves(s.pair, token);
        assertEq(rt, L);
        assertEq(rb, s.realBnbReserve);
        assertGe(rb * s.virtualTokenReserve, s.virtualBnbReserve * rt, "pool price below curve price");
    }

    /// Trading (and graduating) one curve never moves another curve's reserves, and the launchpad's balance is
    /// always exactly the active curves' BNB plus fees.
    function testFuzz_curvesAreIsolated(
        uint256 v0Seed,
        uint256 feeSeed,
        uint256[10] memory historyA,
        uint256[10] memory historyB,
        bool graduateA
    ) public {
        _deploy(v0Seed, feeSeed);
        address a = _newToken();
        address b = _newToken();
        _history(b, historyB);
        IDprkLaunchpad.TokenState memory sb = pad.getTokenState(b);

        _history(a, historyA);
        if (graduateA) {
            uint256 g = _gross(a); // read before vm.prank, or the view call consumes the prank
            vm.prank(dave);
            pad.buy{value: g}(a, 0, block.timestamp);
        }
        IDprkLaunchpad.TokenState memory sb2 = pad.getTokenState(b);
        assertEq(sb2.realBnbReserve, sb.realBnbReserve);
        assertEq(sb2.realTokenReserve, sb.realTokenReserve);

        IDprkLaunchpad.TokenState memory sa = pad.getTokenState(a);
        uint256 activeA = sa.graduated ? 0 : sa.realBnbReserve;
        assertEq(address(pad).balance, activeA + sb2.realBnbReserve + pad.accruedFees());
        if (!sa.graduated) {
            // Quoting more than A's circulating supply never dips into B's BNB or the fee bucket.
            uint256 circulating = S - sa.realTokenReserve;
            try pad.quoteSell(a, circulating + 1e24) returns (uint256 out, uint256 fee) {
                assertLe(out + fee, sa.realBnbReserve);
            } catch (bytes memory err) {
                assertEq(bytes4(err), IDprkLaunchpad.InsufficientRealBnbReserve.selector);
            }
        }
    }
}
