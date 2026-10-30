// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {DprkToken} from "../../src/launchpad/DprkToken.sol";
import {IDprkLaunchpad} from "../../src/launchpad/interfaces/IDprkLaunchpad.sol";
import {IPancakeV2Pair} from "../../src/launchpad/interfaces/IPancakeV2.sol";
import {LaunchpadHandler} from "./handlers/LaunchpadHandler.sol";
import {LaunchpadTestBase} from "./utils/LaunchpadTestBase.sol";

/// @notice Stateful invariants. Runs, depth and fail_on_revert = true come from foundry.toml
/// (FOUNDRY_PROFILE=deep for a longer campaign).
contract DprkLaunchpadInvariantTest is StdInvariant, LaunchpadTestBase {
    LaunchpadHandler internal handler;

    function setUp() public override {
        super.setUp();
        address dave = makeAddr("dave");
        _certify(dave);
        address[] memory actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = dave;
        handler = new LaunchpadHandler(launchpad, wbnb, factory, owner, actors, mallory);

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = LaunchpadHandler.createToken.selector;
        selectors[1] = LaunchpadHandler.buy.selector;
        selectors[2] = LaunchpadHandler.buy.selector; // weight buys and sells up
        selectors[3] = LaunchpadHandler.sell.selector;
        selectors[4] = LaunchpadHandler.sell.selector;
        selectors[5] = LaunchpadHandler.roundTrip.selector;
        selectors[6] = LaunchpadHandler.everyoneExits.selector;
        selectors[7] = LaunchpadHandler.transferToCertified.selector;
        selectors[8] = LaunchpadHandler.transferToLocked.selector;
        selectors[9] = LaunchpadHandler.donateWbnbToPair.selector;
        selectors[10] = LaunchpadHandler.donateTokensToLaunchpad.selector;
        selectors[11] = LaunchpadHandler.claimFees.selector;
        selectors[12] = LaunchpadHandler.togglePause.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Spec: balance >= sum(realBnbReserve) + accruedFees. Graduated curves no longer hold BNB here.
    /// In this closed system (no forced BNB sends) it is an exact equality.
    function invariant_solvency() public view {
        uint256 sum;
        for (uint256 i; i < handler.tokenCount(); ++i) {
            IDprkLaunchpad.TokenState memory s = launchpad.getTokenState(handler.tokens(i));
            if (!s.graduated) sum += s.realBnbReserve;
        }
        assertEq(address(launchpad).balance, sum + launchpad.accruedFees());
    }

    /// @notice Spec: virtual - real offsets are constant for every curve (graduated ones are frozen).
    function invariant_virtualOffsets() public view {
        for (uint256 i; i < handler.tokenCount(); ++i) {
            IDprkLaunchpad.TokenState memory s = launchpad.getTokenState(handler.tokens(i));
            assertEq(s.virtualTokenReserve - s.realTokenReserve, Y0 - S);
            assertEq(s.virtualBnbReserve - s.realBnbReserve, V0);
            assertLe(s.realTokenReserve, S);
        }
    }

    /// @notice Spec: k never decreases (checked after every action by the handler) and stays >= k0.
    function invariant_kNeverDecreases() public view {
        assertFalse(handler.kDecreased());
        for (uint256 i; i < handler.tokenCount(); ++i) {
            address token = handler.tokens(i);
            IDprkLaunchpad.TokenState memory s = launchpad.getTokenState(token);
            uint256 k = s.virtualBnbReserve * s.virtualTokenReserve;
            assertGe(k, V0 * Y0);
            assertEq(k, handler.lastK(token));
        }
    }

    /// @notice Spec: selling every circulating token is always payable from the curve's own real BNB.
    function invariant_sellAlwaysPayable() public view {
        for (uint256 i; i < handler.tokenCount(); ++i) {
            address token = handler.tokens(i);
            IDprkLaunchpad.TokenState memory s = launchpad.getTokenState(token);
            if (s.graduated) continue;
            uint256 circulating = S - s.realTokenReserve;
            (uint256 out, uint256 fee) = launchpad.quoteSell(token, circulating);
            assertLe(out + fee, s.realBnbReserve);
        }
    }

    /// @notice Spec: a buy-then-sell round trip never returns more than was put in.
    function invariant_roundTripNeverProfits() public view {
        assertFalse(handler.roundTripProfit());
    }

    /// @notice Spec: before graduation the launchpad holds at least realTokenReserve + LP_SUPPLY.
    function invariant_tokenBacking() public view {
        for (uint256 i; i < handler.tokenCount(); ++i) {
            address token = handler.tokens(i);
            IDprkLaunchpad.TokenState memory s = launchpad.getTokenState(token);
            assertEq(DprkToken(token).totalSupply(), launchpad.TOTAL_SUPPLY());
            if (!s.graduated) {
                assertGe(DprkToken(token).balanceOf(address(launchpad)), s.realTokenReserve + L);
            }
        }
    }

    /// @notice The pair and uncertified wallets never hold tokens before graduation.
    function invariant_noEarlyHolders() public view {
        assertFalse(handler.lockedTransferSucceeded());
        for (uint256 i; i < handler.tokenCount(); ++i) {
            address token = handler.tokens(i);
            if (DprkToken(token).graduated()) continue;
            assertEq(DprkToken(token).balanceOf(mallory), 0);
            address pair = factory.getPair(token, address(wbnb));
            if (pair != address(0)) {
                assertEq(DprkToken(token).balanceOf(pair), 0);
                assertEq(IPancakeV2Pair(pair).totalSupply(), 0);
            }
        }
    }

    /// @notice Graduated curves are consistent. At the moment of graduation (checked by the handler) the pool
    /// lists at or above the final curve price with exactly LP_SUPPLY tokens and all LP burned. Afterwards the
    /// pool is an ordinary market, and here (no swaps or burns in the handler) its reserves only grow.
    function invariant_graduationState() public view {
        assertFalse(handler.completingBuyOverCharged());
        assertFalse(handler.badGraduation());
        for (uint256 i; i < handler.tokenCount(); ++i) {
            address token = handler.tokens(i);
            IDprkLaunchpad.TokenState memory s = launchpad.getTokenState(token);
            assertEq(s.graduated, s.realTokenReserve == 0);
            assertEq(s.graduated, DprkToken(token).graduated());
            if (!s.graduated) {
                assertEq(s.pair, address(0));
                continue;
            }
            assertGe(s.realBnbReserve, launchpad.graduationBnb());
            IPancakeV2Pair pair = IPancakeV2Pair(s.pair);
            assertEq(address(pair), factory.getPair(token, address(wbnb)));
            assertEq(pair.totalSupply(), pair.balanceOf(DEAD) + 1000);
            (uint256 rb, uint256 rt) = _pairReserves(address(pair), token);
            assertGe(rt, L);
            assertGe(rb, s.realBnbReserve);
        }
    }

    /// @notice Fees accrue exactly as quoted and are only paid out through claimFees.
    function invariant_feeAccounting() public view {
        assertEq(launchpad.accruedFees(), handler.ghostFeesAccrued() - handler.ghostFeesClaimed());
        assertEq(feeRecipient.balance, handler.ghostFeesClaimed());
    }

    function afterInvariant() external view {
        console.log("tokens", handler.tokenCount(), "graduations", handler.graduations());
        console.log("buys", handler.calls("buy"), "sells", handler.calls("sell"));
        console.log("roundTrips", handler.calls("roundTrip"), "exits", handler.calls("everyoneExits"));
        console.log("donations", handler.calls("donateWbnbToPair"), "claims", handler.calls("claimFees"));
    }
}
