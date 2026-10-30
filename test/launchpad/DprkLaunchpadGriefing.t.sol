// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Ported from the independent review's regression suite (ReviewGraduationGrief).

import {console} from "forge-std/console.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KimJongUn} from "../../src/KimJongUn.sol";
import {DprkPass} from "../../src/launchpad/DprkPass.sol";
import {DprkLaunchpad} from "../../src/launchpad/DprkLaunchpad.sol";
import {DprkToken} from "../../src/launchpad/DprkToken.sol";
import {IDprkLaunchpad} from "../../src/launchpad/interfaces/IDprkLaunchpad.sol";
import {IDprkToken} from "../../src/launchpad/interfaces/IDprkToken.sol";
import {IPancakeV2Pair} from "../../src/launchpad/interfaces/IPancakeV2.sol";
import {MockPancakePair} from "./mocks/MockPancakeV2.sol";
import {LaunchpadTestBase} from "./utils/LaunchpadTestBase.sol";

/// @dev Attacker-controlled contract that holds a real pass, so it can legitimately hold curve tokens. It is
/// used to try every ERC-20 route into the PancakeSwap pair before graduation.
contract CertifiedGriefer {
    function certify(KimJongUn kim, DprkPass pass) external {
        kim.pig();
        kim.fuck();
        pass.claim();
    }

    function buy(DprkLaunchpad pad, address token) external payable returns (uint256) {
        return pad.buy{value: msg.value}(token, 0, block.timestamp);
    }

    function exec(address target, bytes calldata data) external returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call(data);
    }

    receive() external payable {}
}

/// @notice Can a third party make the inline graduation revert? Every lever at once, the uint112 bound, sell
/// front-runs, and reference costs.
contract DprkLaunchpadGriefingTest is LaunchpadTestBase {
    CertifiedGriefer internal griefer;

    function setUp() public override {
        super.setUp();
        griefer = new CertifiedGriefer();
        griefer.certify(kimJongUn, pass);
        vm.deal(address(griefer), 1_000 ether);
    }

    /// Every third-party lever at once: protocol fee on, pair pre-created for the predicted token address before
    /// the token exists, WBNB donated before and after creation, synced to (x, 0), skim/mint/burn/swap attempts,
    /// a certified holder trying transfer/transferFrom/zero-value transfers into the pair, a token donation to
    /// the launchpad. Graduation still succeeds and lists at or above the final curve price.
    function test_everyGriefingLeverAtOnce_graduationStillSucceeds() public {
        address treasury = makeAddr("pancakeTreasury");
        factory.setFeeTo(treasury); // BSC mainnet has feeTo set, so the _mintFee/kLast branch is live

        address predicted = vm.computeCreateAddress(address(launchpad), vm.getNonce(address(launchpad)));
        address pair = factory.createPair(predicted, address(wbnb));
        _donate(pair, 5 ether);

        address token = _create(alice);
        assertEq(token, predicted);
        IPancakeV2Pair(pair).sync(); // reserves (5 WBNB, 0 token): the state that breaks router.addLiquidityETH

        // A certified holder tries every route into the pair.
        uint256 held = griefer.buy{value: 1 ether}(launchpad, token);
        assertGt(held, 0);
        uint256[3] memory amounts = [held, 1, 0];
        for (uint256 i; i < amounts.length; ++i) {
            (bool ok, bytes memory err) = griefer.exec(token, abi.encodeCall(IERC20.transfer, (pair, amounts[i])));
            _assertLocked(ok, err);
        }
        griefer.exec(token, abi.encodeCall(IERC20.approve, (mallory, type(uint256).max)));
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IDprkToken.TransferLocked.selector, address(griefer), pair));
        DprkToken(token).transferFrom(address(griefer), pair, held);
        // Relay through another pass holder: still the same receiver check.
        griefer.exec(token, abi.encodeCall(IERC20.transfer, (bob, held / 2)));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IDprkToken.TransferLocked.selector, bob, pair));
        DprkToken(token).transfer(pair, held / 2);

        // Pair-level calls. Nobody can create LP, so totalSupply and kLast stay 0.
        vm.expectRevert(); // sqrt(amount0 * 0) - 1000 underflows
        IPancakeV2Pair(pair).mint(mallory);
        vm.expectRevert(); // division by totalSupply == 0
        IPancakeV2Pair(pair).burn(mallory);
        vm.expectRevert(bytes("Pancake: INSUFFICIENT_LIQUIDITY")); // token reserve 0: nothing can be swapped
        MockPancakePair(pair).swap(0, 1, mallory, "");
        vm.expectRevert(bytes("Pancake: INSUFFICIENT_LIQUIDITY"));
        MockPancakePair(pair).swap(1, 0, mallory, "");
        vm.expectRevert(bytes("Pancake: TRANSFER_FAILED")); // zero-value token leg to an uncertified receiver
        IPancakeV2Pair(pair).skim(mallory);
        IPancakeV2Pair(pair).skim(address(griefer)); // works, moves nothing
        assertEq(IPancakeV2Pair(pair).totalSupply(), 0);
        assertEq(IPancakeV2Pair(pair).kLast(), 0);
        assertEq(DprkToken(token).balanceOf(pair), 0);

        // More unsynced WBNB on top, plus a token donation straight to the launchpad.
        _donate(pair, 2 ether);
        griefer.exec(token, abi.encodeCall(IERC20.transfer, (address(launchpad), held / 4)));

        // Any certified buyer completes; graduation succeeds.
        IDprkLaunchpad.TokenState memory before = _state(token);
        uint256 gross = _grossToComplete(token);
        uint256 carolBnb = carol.balance;
        uint256 out = _buy(carol, token, gross + 1 ether);
        assertEq(out, before.realTokenReserve);
        assertEq(carolBnb - carol.balance, gross);

        IDprkLaunchpad.TokenState memory s = _state(token);
        assertTrue(s.graduated);
        assertEq(s.pair, pair);
        (uint256 rb, uint256 rt) = _pairReserves(pair, token);
        assertEq(rt, L);
        assertEq(rb, s.realBnbReserve + 7 ether);
        // mint credits balance - reserve: the synced 5 WBNB is ignored, the unsynced 2 WBNB is credited to the
        // (burned) first LP position. Either way the donation ends up as unowned pool liquidity.
        assertEq(IPancakeV2Pair(pair).balanceOf(DEAD), Math.sqrt((s.realBnbReserve + 2 ether) * L) - 1000);
        assertEq(IPancakeV2Pair(pair).balanceOf(treasury), 0);
        assertGe(rb * s.virtualTokenReserve, s.virtualBnbReserve * rt, "pool price below curve price");
        assertEq(address(launchpad).balance, launchpad.accruedFees());
    }

    /// The only arithmetic lever on the pair is the uint112 reserve cap. It needs a WBNB donation of
    /// 2^112 - graduationBnb + 1 wei (about 5.19e15 BNB). BNB's whole supply is about 1.4e8 BNB, so this is
    /// infeasible on BSC by a factor of about 3.6e7. It is shown only to bound the vector.
    function test_uint112OverflowNeedsMoreBnbThanExists() public {
        address token = _create(alice);
        address pair = factory.createPair(token, address(wbnb));
        uint256 gross = _grossToComplete(token);
        uint256 r = launchpad.graduationBnb();
        uint256 limit = uint256(type(uint112).max) - r; // the largest donation that still lists

        uint256 snap = vm.snapshotState();
        _donate(pair, limit);
        _buy(bob, token, gross);
        assertTrue(_state(token).graduated);
        vm.revertToState(snap);

        _donate(pair, limit + 1);
        vm.prank(bob);
        vm.expectRevert(bytes("Pancake: OVERFLOW"));
        launchpad.buy{value: gross}(token, 0, block.timestamp);
        console.log("donation needed to overflow (BNB):", (limit + 1) / 1e18);
    }

    /// A seller can front-run a completing buy so that it no longer completes. That only shifts who completes:
    /// the same buyer with an over-sized msg.value (the excess is refunded) still completes, so the curve is
    /// never trapped. Frontends should send a buffer for the last buy, which costs nothing because of the refund.
    function test_sellFrontrunOnlyDelaysCompletion() public {
        address token = _create(alice);
        uint256 bobTokens = _buy(bob, token, 2 ether);
        uint256 remaining = _state(token).realTokenReserve;
        uint256 gross = _grossToComplete(token);

        _sell(bob, token, bobTokens / 100); // front-run

        uint256 snap = vm.snapshotState();
        // Branch A: the exact-gross buy no longer completes. It still succeeds (and buys at least the old
        // remainder, because the sell lowered the price), and anyone can finish the leftover.
        uint256 got = _buy(carol, token, gross);
        assertGe(got, remaining);
        assertFalse(_state(token).graduated);
        uint256 rest = _grossToComplete(token);
        console.log("leftover after front-run, gross to finish (wei):", rest);
        _buy(alice, token, rest);
        assertTrue(_state(token).graduated);
        vm.revertToState(snap);

        // Branch B: the same buyer with a 10% buffer completes, and the excess is refunded.
        uint256 carolBnb = carol.balance;
        _buy(carol, token, gross + gross / 10);
        assertTrue(_state(token).graduated);
        assertLt(carolBnb - carol.balance, gross + gross / 10);
    }

    /// Reference costs with ceilings, so a regression that makes completing buys or the big views too expensive
    /// fails here. The ceilings leave room for real PancakeSwap (createPair there measured 3.56M on the fork) and
    /// stay far below typical eth_call gas caps (50M).
    function test_referenceCosts_stayBounded() public {
        address token = _create(alice);
        _buy(bob, token, 1 ether);
        uint256 gross = _grossToComplete(token);
        vm.prank(carol);
        uint256 g = gasleft();
        launchpad.buy{value: gross}(token, 0, block.timestamp);
        uint256 completingWithCreatePair = g - gasleft();
        console.log("completing buy incl. createPair (mock):", completingWithCreatePair);
        assertLt(completingWithCreatePair, 3_000_000);

        address token2 = _create(alice);
        factory.createPair(token2, address(wbnb));
        uint256 gross2 = _grossToComplete(token2);
        vm.prank(carol);
        g = gasleft();
        launchpad.buy{value: gross2}(token2, 0, block.timestamp);
        uint256 completingPrecreated = g - gasleft();
        console.log("completing buy, pair pre-created (mock):", completingPrecreated);
        assertLt(completingPrecreated, 500_000);

        string memory name64 = _repeat("a", 64);
        string memory symbol16 = _repeat("S", 16);
        string memory meta1024 = _repeat("m", 1024);
        vm.prank(alice);
        g = gasleft();
        launchpad.createToken(name64, symbol16, meta1024, 0, block.timestamp);
        uint256 createMax = g - gasleft();
        console.log("createToken, max name/symbol/metadata:", createMax);
        assertLt(createMax, 2_500_000);

        for (uint256 i; i < 99; ++i) {
            vm.prank(alice);
            launchpad.createToken(name64, symbol16, meta1024, 0, block.timestamp);
        }
        g = gasleft();
        launchpad.getTokenInfos(0, 100);
        uint256 page = g - gasleft();
        console.log("getTokenInfos(0, 100), max-size metadata:", page);
        assertLt(page, 30_000_000);
        g = gasleft();
        pass.tokenURI(1);
        uint256 uri = g - gasleft();
        console.log("pass.tokenURI:", uri);
        assertLt(uri, 2_000_000);
    }

    // ------------------------------------------------------------------------------------------- helpers

    function _assertLocked(bool ok, bytes memory err) internal pure {
        assertFalse(ok, "transfer into the pair succeeded");
        assertEq(bytes4(err), IDprkToken.TransferLocked.selector);
    }

    function _donate(address pair, uint256 amount) internal {
        vm.deal(mallory, amount);
        vm.startPrank(mallory);
        wbnb.deposit{value: amount}();
        wbnb.transfer(pair, amount);
        vm.stopPrank();
    }

    function _repeat(string memory s, uint256 n) internal pure returns (string memory) {
        bytes memory unit = bytes(s);
        bytes memory out = new bytes(unit.length * n);
        for (uint256 i; i < out.length; ++i) {
            out[i] = unit[i % unit.length];
        }
        return string(out);
    }
}
