// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DprkToken} from "../../src/launchpad/DprkToken.sol";
import {IDprkLaunchpad} from "../../src/launchpad/interfaces/IDprkLaunchpad.sol";
import {IDprkToken} from "../../src/launchpad/interfaces/IDprkToken.sol";
import {IPancakeV2Pair} from "../../src/launchpad/interfaces/IPancakeV2.sol";
import {MockPancakePair} from "./mocks/MockPancakeV2.sol";
import {LaunchpadTestBase} from "./utils/LaunchpadTestBase.sol";

contract DprkLaunchpadGraduationTest is LaunchpadTestBase {
    // ------------------------------------------------------------------------------------------- completing buy

    function test_completingBuy_exactRemainderAndRefund() public {
        address token = _create(alice);
        _buy(bob, token, 1 ether);
        IDprkLaunchpad.TokenState memory before = _state(token);
        uint256 remaining = before.realTokenReserve;

        uint256 gross = _grossToComplete(token);
        uint256 extra = 5 ether + 12_345;
        (uint256 quoted, uint256 fee, uint256 accepted, uint256 refund) = launchpad.quoteBuy(token, gross + extra);
        assertEq(quoted, remaining);
        assertEq(accepted, gross);
        assertEq(refund, extra);

        // The required input is the ceil of the exact amount, and it's minimal: one wei less doesn't complete.
        uint256 x = before.virtualBnbReserve;
        uint256 y = before.virtualTokenReserve;
        uint256 netRequired = Math.mulDiv(x, y, Y_END, Math.Rounding.Ceil) - x;
        assertEq(accepted - fee, netRequired);
        assertEq(accepted, Math.mulDiv(netRequired, 10_000, 10_000 - FEE_BPS, Math.Rounding.Ceil));
        (uint256 short,,, uint256 shortRefund) = launchpad.quoteBuy(token, gross - 1);
        assertLt(short, remaining);
        assertEq(shortRefund, 0);

        uint256 carolBnb = carol.balance;
        uint256 feesBefore = launchpad.accruedFees();
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit IDprkLaunchpad.Trade(
            token, carol, true, accepted, remaining, fee, x + netRequired, Y_END, before.realBnbReserve + netRequired
        );
        vm.expectEmit(true, false, false, false, address(launchpad));
        emit IDprkLaunchpad.Graduated(token, address(0), 0, 0, 0);
        uint256 out = _buy(carol, token, gross + extra);

        assertEq(out, remaining);
        assertEq(DprkToken(token).balanceOf(carol), remaining);
        assertEq(carol.balance, carolBnb - accepted, "refund");
        assertEq(launchpad.accruedFees(), feesBefore + fee);
        _assertGraduated(token, before.realBnbReserve + netRequired);
    }

    function test_completingBuy_exactAmountNoRefund() public {
        address token = _create(alice);
        uint256 gross = _grossToComplete(token);
        uint256 bobBnb = bob.balance;
        assertEq(_buy(bob, token, gross), S);
        assertEq(bob.balance, bobBnb - gross);
        _assertGraduated(token, _state(token).realBnbReserve);
        assertGe(_state(token).realBnbReserve, launchpad.graduationBnb());
    }

    function test_oneWeiShortThenDustCompletes() public {
        address token = _create(alice);
        uint256 gross = _grossToComplete(token);
        _buy(bob, token, gross - 1);
        IDprkLaunchpad.TokenState memory s = _state(token);
        assertFalse(s.graduated);
        assertGt(s.realTokenReserve, 0);

        uint256 rest = _grossToComplete(token);
        assertLe(rest, 3); // a couple of wei finish it
        assertEq(_buy(carol, token, rest), s.realTokenReserve);
        _assertGraduated(token, _state(token).realBnbReserve);
    }

    function test_creatorInitialBuyCompletesCurve() public {
        (uint256 quoted, uint256 fee, uint256 accepted,) = launchpad.quoteCreateBuy(type(uint256).max);
        assertEq(quoted, S);
        uint256 value = accepted + 1 ether;

        uint256 aliceBnb = alice.balance;
        vm.prank(alice);
        (address token, uint256 tokensOut) =
            launchpad.createToken{value: value}(NAME, SYMBOL, METADATA, S, block.timestamp);

        assertEq(tokensOut, S);
        assertEq(DprkToken(token).balanceOf(alice), S);
        assertEq(alice.balance, aliceBnb - accepted);
        assertEq(launchpad.accruedFees(), fee);
        assertEq(_state(token).realBnbReserve, launchpad.graduationBnb()); // k0 path: no prior rounding
        _assertGraduated(token, launchpad.graduationBnb());
    }

    function test_afterGraduation() public {
        address token = _create(alice);
        uint256 bobTokens = _buy(bob, token, 1 ether);
        _buy(carol, token, _grossToComplete(token));

        // Trading on the curve is over.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IDprkLaunchpad.AlreadyGraduated.selector, token));
        launchpad.buy{value: 1 ether}(token, 0, block.timestamp);
        vm.startPrank(bob);
        DprkToken(token).approve(address(launchpad), bobTokens);
        vm.expectRevert(abi.encodeWithSelector(IDprkLaunchpad.AlreadyGraduated.selector, token));
        launchpad.sell(token, bobTokens, 0, block.timestamp);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IDprkLaunchpad.AlreadyGraduated.selector, token));
        launchpad.quoteBuy(token, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IDprkLaunchpad.AlreadyGraduated.selector, token));
        launchpad.quoteSell(token, 1 ether);

        // The token is a plain ERC-20 now: an uncertified wallet can receive it and trade on the pair.
        vm.prank(bob);
        DprkToken(token).transfer(mallory, bobTokens);
        address pair = _state(token).pair;
        _swapTokensForWbnb(mallory, token, pair, bobTokens);
        assertGt(wbnb.balanceOf(mallory), 0);
        _swapWbnbForTokens(mallory, token, pair, wbnb.balanceOf(mallory) / 2);
        assertGt(DprkToken(token).balanceOf(mallory), 0);
    }

    // ------------------------------------------------------------------------------------------- griefing

    function test_grief_pairPreCreated() public {
        address token = _create(alice);
        address pair = factory.createPair(address(wbnb), token);
        _buy(bob, token, 1 ether);
        _buy(carol, token, _grossToComplete(token));
        assertEq(_state(token).pair, pair);
        _assertGraduated(token, _state(token).realBnbReserve);
    }

    function test_grief_pairCreatedBeforeTokenExists() public {
        // CREATE addresses are predictable, so an attacker can create the pair before the token is deployed.
        address predicted = vm.computeCreateAddress(address(launchpad), vm.getNonce(address(launchpad)));
        address pair = factory.createPair(predicted, address(wbnb));
        address token = _create(alice);
        assertEq(token, predicted);
        _buy(bob, token, _grossToComplete(token));
        assertEq(_state(token).pair, pair);
        _assertGraduated(token, _state(token).realBnbReserve);
    }

    function test_grief_wbnbDonatedAndSynced() public {
        address token = _create(alice);
        address pair = factory.createPair(token, address(wbnb));
        _donateWbnb(mallory, pair, 7 ether);
        IPancakeV2Pair(pair).sync();
        (uint256 rb, uint256 rt) = _pairReserves(pair, token);
        assertEq(rb, 7 ether);
        assertEq(rt, 0); // reserves (x, 0): router.addLiquidityETH would revert in quote() here

        _buy(bob, token, _grossToComplete(token));
        uint256 realBnb = _state(token).realBnbReserve;
        (rb, rt) = _pairReserves(pair, token);
        assertEq(rb, realBnb + 7 ether);
        assertEq(rt, L);
        // The mint credited only balance - reserve: LP = sqrt(realBnb * L) - 1000, all burned.
        assertEq(IPancakeV2Pair(pair).balanceOf(DEAD), Math.sqrt(realBnb * L) - 1000);
        _assertPoolPriceAtLeastCurve(token);
    }

    function test_grief_wbnbDonatedNotSynced() public {
        address token = _create(alice);
        address pair = factory.createPair(token, address(wbnb));
        _donateWbnb(mallory, pair, 3 ether);
        _buy(bob, token, _grossToComplete(token));
        (uint256 rb, uint256 rt) = _pairReserves(pair, token);
        assertEq(rb, _state(token).realBnbReserve + 3 ether);
        assertEq(rt, L);
        _assertPoolPriceAtLeastCurve(token);
    }

    function test_grief_dustDonationAndRepeatedSyncs() public {
        address token = _create(alice);
        address pair = factory.createPair(token, address(wbnb));
        for (uint256 i = 1; i <= 5; ++i) {
            _donateWbnb(mallory, pair, i);
            IPancakeV2Pair(pair).sync();
        }
        _buy(bob, token, 2 ether);
        _buy(carol, token, _grossToComplete(token));
        _assertGraduated(token, _state(token).realBnbReserve);
    }

    function test_grief_skimAndMintBeforeGraduation() public {
        address token = _create(alice);
        address pair = factory.createPair(token, address(wbnb));
        _donateWbnb(mallory, pair, 1 ether);

        // Nobody can mint LP before graduation: there are no tokens in the pair (sqrt(x * 0) - 1000 underflows).
        vm.expectRevert();
        IPancakeV2Pair(pair).mint(mallory);
        // skim to an uncertified wallet reverts on the (zero-value) token leg (TransferLocked, wrapped by the
        // pair); to a pass holder it works. Neither touches the graduation path.
        vm.expectRevert(bytes("Pancake: TRANSFER_FAILED"));
        IPancakeV2Pair(pair).skim(mallory);
        IPancakeV2Pair(pair).skim(bob);
        assertEq(wbnb.balanceOf(bob), 1 ether);

        _buy(bob, token, _grossToComplete(token));
        _assertGraduated(token, _state(token).realBnbReserve);
        assertEq(IPancakeV2Pair(pair).totalSupply(), IPancakeV2Pair(pair).balanceOf(DEAD) + 1000);
    }

    function test_grief_pairAndUncertifiedCannotReceiveTokens() public {
        address token = _create(alice);
        address pair = factory.createPair(token, address(wbnb));
        uint256 bought = _buy(bob, token, 1 ether);

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IDprkToken.TransferLocked.selector, bob, pair));
        DprkToken(token).transfer(pair, bought);
        vm.expectRevert(abi.encodeWithSelector(IDprkToken.TransferLocked.selector, bob, mallory));
        DprkToken(token).transfer(mallory, 1);
        DprkToken(token).approve(mallory, bought);
        vm.stopPrank();

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IDprkToken.TransferLocked.selector, bob, pair));
        DprkToken(token).transferFrom(bob, pair, bought);
        assertEq(DprkToken(token).balanceOf(pair), 0);
    }

    function test_grief_tokenDonationToLaunchpadStaysInert() public {
        address token = _create(alice);
        uint256 bought = _buy(bob, token, 1 ether);
        vm.prank(bob);
        DprkToken(token).transfer(address(launchpad), bought / 4);
        _buy(carol, token, _grossToComplete(token));
        // Exactly LP_SUPPLY went to the pair; the donation stays (effectively burned) in the launchpad.
        _assertGraduated(token, _state(token).realBnbReserve, bought / 4);
    }

    function test_grief_feeToOnMintFeePath() public {
        address treasury = makeAddr("pancakeTreasury");
        factory.setFeeTo(treasury);
        address token = _create(alice);
        address pair = factory.createPair(token, address(wbnb));
        _donateWbnb(mallory, pair, 1 ether);
        IPancakeV2Pair(pair).sync();

        _buy(bob, token, _grossToComplete(token));
        _assertGraduated(token, _state(token).realBnbReserve);
        assertEq(IPancakeV2Pair(pair).balanceOf(treasury), 0); // first mint: kLast was 0
        (uint256 rb, uint256 rt) = _pairReserves(pair, token);
        assertEq(IPancakeV2Pair(pair).kLast(), rb * rt);

        // Later activity accrues the protocol fee as normal.
        uint256 bobTokens = DprkToken(token).balanceOf(bob);
        vm.prank(bob);
        DprkToken(token).transfer(mallory, bobTokens / 10);
        _swapTokensForWbnb(mallory, token, pair, bobTokens / 10);
        vm.prank(bob);
        DprkToken(token).transfer(pair, 1e18);
        _donateWbnb(bob, pair, 1 ether);
        IPancakeV2Pair(pair).mint(bob);
        assertGt(IPancakeV2Pair(pair).balanceOf(treasury), 0);
    }

    // ------------------------------------------------------------------------------------------- price continuity

    function test_priceContinuity_measured() public {
        _measure(V0, FEE_BPS, 0, "V0=1 BNB, 1% fee, single sell-out");
        _measure(8 ether, 100, 0, "V0=8 BNB, 1% fee, single sell-out");
        _measure(8 ether, 100, 40, "V0=8 BNB, 1% fee, 40 buy/sell rounds");
        _measure(0.5 ether, 500, 25, "V0=0.5 BNB, 5% fee, 25 rounds");
        _measure(1e9, 0, 10, "V0=1 gwei, no fee, 10 rounds");
        _measure(1e25, 0, 5, "V0=1e25 (max), no fee, 5 rounds");
    }

    function _measure(uint256 v0, uint16 feeBps, uint256 rounds, string memory label) internal {
        // Fresh launchpad per configuration.
        launchpad = _deployLaunchpad(v0, feeBps);
        vm.deal(bob, type(uint128).max);
        vm.deal(carol, type(uint128).max);
        address token = _create(alice);
        uint256 step = Math.max(_grossToComplete(token) / 13, 1e9);
        for (uint256 i; i < rounds; ++i) {
            // Never complete inside the loop; the last buy below does that.
            uint256 amount = Math.min(step * (1 + i % 3), _grossToComplete(token) / 2);
            if (amount < 1e9) break;
            uint256 got = _buy(bob, token, amount);
            _sell(bob, token, got / 2);
        }
        _buy(carol, token, _grossToComplete(token));
        IDprkLaunchpad.TokenState memory s = _state(token);
        (uint256 rb, uint256 rt) = _pairReserves(s.pair, token);

        // Listing price rb / rt vs the final curve price vBnb / vToken, compared exactly by cross-multiplying.
        uint256 lhs = rb * s.virtualTokenReserve;
        uint256 rhs = s.virtualBnbReserve * rt;
        assertGe(lhs, rhs, "pool price below curve price");
        uint256 relDevE36 = Math.mulDiv(lhs - rhs, 1e36, rhs);
        // BNB the pool holds beyond what the exact final curve price implies for LP_SUPPLY tokens.
        uint256 excessWei = (lhs - rhs) / s.virtualTokenReserve;
        console.log(label);
        console.log("  graduation BNB over 3*V0 (wei):", s.realBnbReserve - 3 * v0);
        console.log("  pool BNB above curve price (wei):", excessWei);
        console.log("  pool/curve - 1, scaled 1e36:", relDevE36);
        // Rounding adds at most ~4 wei of graduation BNB per sell, so ~1 wei of excess per sell.
        assertLe(excessWei, rounds + 1, "listing price drifted above curve price by more than rounding");
    }

    // ------------------------------------------------------------------------------------------- helpers

    function _assertGraduated(address token, uint256 bnbLiquidity) internal view {
        _assertGraduated(token, bnbLiquidity, 0);
    }

    /// @dev Checks the state right after graduation. `donatedToLaunchpad` is the number of tokens sent straight to
    /// the launchpad (not sold). They are the only tokens it may still hold.
    function _assertGraduated(address token, uint256 bnbLiquidity, uint256 donatedToLaunchpad) internal view {
        IDprkLaunchpad.TokenState memory s = _state(token);
        assertTrue(s.graduated);
        assertEq(s.realTokenReserve, 0);
        assertEq(s.realBnbReserve, bnbLiquidity);
        assertEq(s.virtualTokenReserve, Y_END);
        assertEq(s.virtualBnbReserve, bnbLiquidity + launchpad.initialVirtualBnbReserve());
        assertEq(launchpad.progressBps(token), 10_000);
        assertTrue(DprkToken(token).graduated());

        address pair = s.pair;
        assertEq(pair, factory.getPair(token, address(wbnb)));
        assertEq(DprkToken(token).balanceOf(pair), L); // nothing could reach the pair before graduation
        assertGe(wbnb.balanceOf(pair), bnbLiquidity); // plus any donations
        uint256 burned = IPancakeV2Pair(pair).balanceOf(DEAD);
        assertGt(burned, 0);
        assertEq(IPancakeV2Pair(pair).balanceOf(address(0)), 1000);
        assertEq(IPancakeV2Pair(pair).totalSupply(), burned + 1000); // all LP minted at graduation is burned
        assertEq(IPancakeV2Pair(pair).balanceOf(address(launchpad)), 0);
        // No curve tokens left behind: the buyer got the remainder and the pair got LP_SUPPLY.
        assertEq(DprkToken(token).balanceOf(address(launchpad)), donatedToLaunchpad);
        _assertPoolPriceAtLeastCurve(token);
    }

    function _assertPoolPriceAtLeastCurve(address token) internal view {
        IDprkLaunchpad.TokenState memory s = _state(token);
        (uint256 rb, uint256 rt) = _pairReserves(s.pair, token);
        assertGe(rb * s.virtualTokenReserve, s.virtualBnbReserve * rt, "pool price below curve price");
    }

    function _donateWbnb(address from, address pair, uint256 amount) internal {
        vm.deal(from, from.balance + amount);
        vm.startPrank(from);
        wbnb.deposit{value: amount}();
        wbnb.transfer(pair, amount);
        vm.stopPrank();
    }

    function _swapTokensForWbnb(address trader, address token, address pair, uint256 amountIn) internal {
        (uint256 rb, uint256 rt) = _pairReserves(pair, token);
        uint256 out = amountIn * 9975 * rb / (rt * 10_000 + amountIn * 9975);
        vm.startPrank(trader);
        DprkToken(token).transfer(pair, amountIn);
        if (IPancakeV2Pair(pair).token0() == token) MockPancakePair(pair).swap(0, out, trader, "");
        else MockPancakePair(pair).swap(out, 0, trader, "");
        vm.stopPrank();
    }

    function _swapWbnbForTokens(address trader, address token, address pair, uint256 amountIn) internal {
        (uint256 rb, uint256 rt) = _pairReserves(pair, token);
        uint256 out = amountIn * 9975 * rt / (rb * 10_000 + amountIn * 9975);
        vm.startPrank(trader);
        wbnb.transfer(pair, amountIn);
        if (IPancakeV2Pair(pair).token0() == token) MockPancakePair(pair).swap(out, 0, trader, "");
        else MockPancakePair(pair).swap(0, out, trader, "");
        vm.stopPrank();
    }
}
