// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {stdError} from "forge-std/StdError.sol";
import {DprkLaunchpad} from "../../src/launchpad/DprkLaunchpad.sol";
import {DprkToken} from "../../src/launchpad/DprkToken.sol";
import {IDprkLaunchpad} from "../../src/launchpad/interfaces/IDprkLaunchpad.sol";
import {LaunchpadTestBase} from "./utils/LaunchpadTestBase.sol";

contract DprkLaunchpadTest is LaunchpadTestBase {
    // ------------------------------------------------------------------------------------------- config

    function test_constants() public view {
        assertEq(launchpad.TOTAL_SUPPLY(), 1_000_000_000e18);
        assertEq(launchpad.CURVE_SUPPLY(), S);
        assertEq(launchpad.LP_SUPPLY(), L);
        assertEq(launchpad.initialVirtualTokenReserve(), Y0);
        assertEq(Y0, 1_066_666_666_666_666_666_666_666_666);
        assertEq(launchpad.FINAL_VIRTUAL_TOKEN_RESERVE(), Y_END);
        assertEq(launchpad.initialVirtualBnbReserve(), V0);
        assertEq(launchpad.feeBps(), FEE_BPS);
        assertEq(launchpad.pass(), address(pass));
        assertEq(launchpad.pancakeFactory(), address(factory));
        assertEq(launchpad.wbnb(), address(wbnb));
        assertEq(launchpad.feeRecipient(), feeRecipient);
        assertEq(launchpad.owner(), owner);
        assertFalse(launchpad.paused());
        assertEq(launchpad.accruedFees(), 0);
        assertEq(launchpad.tokenCount(), 0);
        assertEq(launchpad.LP_RECIPIENT(), DEAD);
    }

    function test_graduationBnb_isThreeV0PlusAtMostOneWei() public {
        assertEq(launchpad.graduationBnb(), Math.mulDiv(V0, Y0, Y_END, Math.Rounding.Ceil) - V0);
        assertEq(launchpad.graduationBnb(), 3 * V0 + 1);
        // Mainnet / testnet defaults.
        assertEq(_deployLaunchpad(8 ether, 100).graduationBnb(), 24 ether + 1);
        assertEq(_deployLaunchpad(0.5 ether, 100).graduationBnb(), 1.5 ether + 1);
    }

    function test_constructor_validation() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(IDprkLaunchpad.InvalidConfiguration.selector);
        new DprkLaunchpad(eoa, address(factory), address(wbnb), feeRecipient, owner, V0, 100);
        vm.expectRevert(IDprkLaunchpad.InvalidConfiguration.selector);
        new DprkLaunchpad(address(pass), eoa, address(wbnb), feeRecipient, owner, V0, 100);
        vm.expectRevert(IDprkLaunchpad.InvalidConfiguration.selector);
        new DprkLaunchpad(address(pass), address(factory), eoa, feeRecipient, owner, V0, 100);
        vm.expectRevert(IDprkLaunchpad.InvalidConfiguration.selector);
        new DprkLaunchpad(address(pass), address(factory), address(wbnb), address(0), owner, V0, 100);
        vm.expectRevert(IDprkLaunchpad.InvalidConfiguration.selector);
        new DprkLaunchpad(address(pass), address(factory), address(wbnb), feeRecipient, owner, V0, 501);
        vm.expectRevert(IDprkLaunchpad.InvalidConfiguration.selector);
        new DprkLaunchpad(address(pass), address(factory), address(wbnb), feeRecipient, owner, 1e9 - 1, 100);
        vm.expectRevert(IDprkLaunchpad.InvalidConfiguration.selector);
        new DprkLaunchpad(address(pass), address(factory), address(wbnb), feeRecipient, owner, 1e25 + 1, 100);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new DprkLaunchpad(address(pass), address(factory), address(wbnb), feeRecipient, address(0), V0, 100);

        // Boundaries are accepted.
        _deployLaunchpad(1e9, 0);
        _deployLaunchpad(1e25, 500);
    }

    // ------------------------------------------------------------------------------------------- createToken

    function test_createToken_noBuy() public {
        vm.expectEmit(false, true, false, true, address(launchpad));
        emit IDprkLaunchpad.TokenCreated(address(0), alice, NAME, SYMBOL, METADATA);
        vm.prank(alice);
        (address token, uint256 tokensOut) = launchpad.createToken(NAME, SYMBOL, METADATA, 0, block.timestamp);

        assertEq(tokensOut, 0);
        assertTrue(launchpad.isLaunchToken(token));
        assertEq(launchpad.tokenCount(), 1);
        assertEq(launchpad.tokenAt(0), token);
        assertEq(DprkToken(token).balanceOf(address(launchpad)), launchpad.TOTAL_SUPPLY());

        IDprkLaunchpad.TokenState memory s = _state(token);
        assertEq(s.creator, alice);
        assertEq(s.createdAt, block.timestamp);
        assertFalse(s.graduated);
        assertEq(s.pair, address(0));
        assertEq(s.virtualBnbReserve, V0);
        assertEq(s.virtualTokenReserve, Y0);
        assertEq(s.realBnbReserve, 0);
        assertEq(s.realTokenReserve, S);
        assertEq(launchpad.progressBps(token), 0);
        assertEq(address(launchpad).balance, 0);
    }

    function test_createToken_withInitialBuy() public {
        uint256 value = 0.3 ether;
        (uint256 quoted, uint256 fee, uint256 accepted, uint256 refund) = launchpad.quoteCreateBuy(value);
        assertEq(accepted, value);
        assertEq(refund, 0);
        assertEq(fee, 0.003 ether);

        vm.prank(alice);
        (address token, uint256 tokensOut) =
            launchpad.createToken{value: value}(NAME, SYMBOL, METADATA, quoted, block.timestamp);

        assertEq(tokensOut, quoted);
        assertEq(DprkToken(token).balanceOf(alice), quoted);
        assertEq(launchpad.accruedFees(), fee);
        IDprkLaunchpad.TokenState memory s = _state(token);
        assertEq(s.realBnbReserve, value - fee);
        assertEq(s.realTokenReserve, S - quoted);
        assertEq(address(launchpad).balance, value);
    }

    function test_createToken_gate() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IDprkLaunchpad.NotCertified.selector, mallory));
        launchpad.createToken(NAME, SYMBOL, METADATA, 0, block.timestamp);
    }

    function test_createToken_paused() public {
        vm.prank(owner);
        launchpad.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(IDprkLaunchpad.LaunchpadPaused.selector);
        launchpad.createToken(NAME, SYMBOL, METADATA, 0, block.timestamp);
    }

    function test_createToken_deadline() public {
        vm.warp(1000);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDprkLaunchpad.DeadlineExpired.selector, 999, 1000));
        launchpad.createToken(NAME, SYMBOL, METADATA, 0, 999);
        vm.prank(alice);
        launchpad.createToken(NAME, SYMBOL, METADATA, 0, 1000); // deadline == now is fine
    }

    function test_createToken_metadataLimits() public {
        string memory b64 = _repeat("a", 64);
        string memory b16 = _repeat("S", 16);
        string memory b1024 = _repeat("m", 1024);

        vm.startPrank(alice);
        launchpad.createToken(b64, b16, b1024, 0, block.timestamp); // exact limits are fine
        launchpad.createToken("x", "y", "", 0, block.timestamp); // minimums, empty metadata

        _expectInvalid("", "S", "");
        _expectInvalid(_repeat("a", 65), "S", "");
        _expectInvalid("n", "", "");
        _expectInvalid("n", _repeat("S", 17), "");
        _expectInvalid("n", "S", _repeat("m", 1025));
        // Limits are bytes, not characters: 22 Hangul syllables are 66 bytes.
        _expectInvalid(_repeat(unicode"김", 22), "S", "");
        launchpad.createToken(_repeat(unicode"김", 21), unicode"김정은", "", 0, block.timestamp);
        vm.stopPrank();
        assertEq(launchpad.tokenCount(), 3);
    }

    function test_createToken_minTokensOutWithoutValue() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDprkLaunchpad.SlippageExceeded.selector, 1, 0));
        launchpad.createToken(NAME, SYMBOL, METADATA, 1, block.timestamp);
    }

    function test_createToken_initialBuySlippageAndDust() public {
        (uint256 quoted,,,) = launchpad.quoteCreateBuy(1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDprkLaunchpad.SlippageExceeded.selector, quoted + 1, quoted));
        launchpad.createToken{value: 1 ether}(NAME, SYMBOL, METADATA, quoted + 1, block.timestamp);

        // 1 wei: net = floor(1 * 9900 / 10000) = 0, so nothing would be bought.
        vm.prank(alice);
        vm.expectRevert(IDprkLaunchpad.DustAmount.selector);
        launchpad.createToken{value: 1}(NAME, SYMBOL, METADATA, 0, block.timestamp);
    }

    // ------------------------------------------------------------------------------------------- buy

    function test_buy_matchesQuoteAndAccounting() public {
        address token = _create(alice);
        uint256 value = 0.25 ether;
        (uint256 quoted, uint256 fee, uint256 accepted, uint256 refund) = launchpad.quoteBuy(token, value);
        assertEq(fee, Math.mulDiv(value, FEE_BPS, 10_000, Math.Rounding.Ceil));
        assertEq(accepted, value);
        assertEq(refund, 0);
        uint256 net = value - fee;
        assertEq(quoted, Math.mulDiv(Y0, net, V0 + net));

        vm.expectEmit(true, true, true, true, address(launchpad));
        emit IDprkLaunchpad.Trade(token, bob, true, value, quoted, fee, V0 + net, Y0 - quoted, net);
        uint256 out = _buy(bob, token, value);

        assertEq(out, quoted);
        assertEq(DprkToken(token).balanceOf(bob), quoted);
        assertEq(launchpad.accruedFees(), fee);
        IDprkLaunchpad.TokenState memory s = _state(token);
        assertEq(s.realBnbReserve, net);
        assertEq(s.realTokenReserve, S - quoted);
        assertEq(s.virtualBnbReserve - s.realBnbReserve, V0);
        assertEq(s.virtualTokenReserve - s.realTokenReserve, Y0 - S);
        assertGe(_k(s), V0 * Y0);
        assertEq(address(launchpad).balance, value);
    }

    function test_buy_priceIncreases() public {
        address token = _create(alice);
        uint256 first = _buy(bob, token, 1 ether);
        uint256 second = _buy(carol, token, 1 ether);
        assertLt(second, first);
    }

    function test_buy_reverts() public {
        address token = _create(alice);

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IDprkLaunchpad.NotCertified.selector, mallory));
        launchpad.buy{value: 1 ether}(token, 0, block.timestamp);

        vm.prank(bob);
        vm.expectRevert(IDprkLaunchpad.ZeroAmount.selector);
        launchpad.buy(token, 0, block.timestamp);

        address unknown = makeAddr("unknown");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IDprkLaunchpad.UnknownToken.selector, unknown));
        launchpad.buy{value: 1 ether}(unknown, 0, block.timestamp);

        vm.prank(bob);
        vm.expectRevert(IDprkLaunchpad.DustAmount.selector);
        launchpad.buy{value: 1}(token, 0, block.timestamp);

        (uint256 quoted,,,) = launchpad.quoteBuy(token, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IDprkLaunchpad.SlippageExceeded.selector, quoted + 1, quoted));
        launchpad.buy{value: 1 ether}(token, quoted + 1, block.timestamp);

        vm.warp(500);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IDprkLaunchpad.DeadlineExpired.selector, 499, 500));
        launchpad.buy{value: 1 ether}(token, 0, 499);

        vm.prank(owner);
        launchpad.setPaused(true);
        vm.prank(bob);
        vm.expectRevert(IDprkLaunchpad.LaunchpadPaused.selector);
        launchpad.buy{value: 1 ether}(token, 0, block.timestamp);
    }

    function test_buy_zeroFeeLaunchpad() public {
        DprkLaunchpad pad = _deployLaunchpad(V0, 0);
        address token = _create(pad, alice, 0);
        (uint256 quoted, uint256 fee,,) = pad.quoteBuy(token, 1);
        assertEq(fee, 0);
        assertGt(quoted, 0); // 1 wei buys ~1e9 token-wei at V0 = 1 BNB
        _buy(pad, bob, token, 1 ether);
        assertEq(pad.accruedFees(), 0);
        vm.expectRevert(IDprkLaunchpad.NoFeesAccrued.selector);
        pad.claimFees();
    }

    // ------------------------------------------------------------------------------------------- sell

    function test_sell_matchesQuoteAndAccounting() public {
        address token = _create(alice);
        uint256 bought = _buy(bob, token, 2 ether);
        IDprkLaunchpad.TokenState memory before = _state(token);
        uint256 feesBefore = launchpad.accruedFees();

        uint256 amount = bought / 3;
        (uint256 quoted, uint256 fee) = launchpad.quoteSell(token, amount);
        uint256 gross = Math.mulDiv(before.virtualBnbReserve, amount, before.virtualTokenReserve + amount);
        assertEq(fee, Math.mulDiv(gross, FEE_BPS, 10_000, Math.Rounding.Ceil));
        assertEq(quoted, gross - fee);

        uint256 bobBnb = bob.balance;
        vm.startPrank(bob);
        DprkToken(token).approve(address(launchpad), amount);
        vm.expectEmit(true, true, true, true, address(launchpad));
        emit IDprkLaunchpad.Trade(
            token,
            bob,
            false,
            quoted,
            amount,
            fee,
            before.virtualBnbReserve - gross,
            before.virtualTokenReserve + amount,
            before.realBnbReserve - gross
        );
        uint256 out = launchpad.sell(token, amount, quoted, block.timestamp);
        vm.stopPrank();

        assertEq(out, quoted);
        assertEq(bob.balance, bobBnb + quoted);
        assertEq(launchpad.accruedFees(), feesBefore + fee);
        IDprkLaunchpad.TokenState memory s = _state(token);
        assertEq(s.realBnbReserve, before.realBnbReserve - gross);
        assertEq(s.realTokenReserve, before.realTokenReserve + amount);
        assertGe(_k(s), _k(before));
        assertEq(address(launchpad).balance, s.realBnbReserve + launchpad.accruedFees());
    }

    function test_sell_reverts() public {
        address token = _create(alice);
        uint256 bought = _buy(bob, token, 1 ether);
        vm.prank(bob);
        DprkToken(token).approve(address(launchpad), type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(IDprkLaunchpad.ZeroAmount.selector);
        launchpad.sell(token, 0, 0, block.timestamp);

        address unknown = makeAddr("unknown");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IDprkLaunchpad.UnknownToken.selector, unknown));
        launchpad.sell(unknown, 1, 0, block.timestamp);

        // A handful of token-wei is worth 0 wei after rounding.
        vm.prank(bob);
        vm.expectRevert(IDprkLaunchpad.DustAmount.selector);
        launchpad.sell(token, 1000, 0, block.timestamp);

        (uint256 quoted,) = launchpad.quoteSell(token, bought);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IDprkLaunchpad.SlippageExceeded.selector, quoted + 1, quoted));
        launchpad.sell(token, bought, quoted + 1, block.timestamp);

        vm.warp(77);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IDprkLaunchpad.DeadlineExpired.selector, 76, 77));
        launchpad.sell(token, bought, 0, 76);

        // More than all circulating tokens: the reserve backstop rejects it before any transfer.
        vm.prank(bob);
        vm.expectPartialRevert(IDprkLaunchpad.InsufficientRealBnbReserve.selector);
        launchpad.sell(token, bought + 1e18, 0, block.timestamp);

        // More than the seller holds (but less than circulating): the token pull fails.
        _buy(carol, token, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, bought, bought + 1));
        launchpad.sell(token, bought + 1, 0, block.timestamp);
    }

    function test_sell_needsAllowance() public {
        address token = _create(alice);
        uint256 bought = _buy(bob, token, 1 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(launchpad), 0, bought)
        );
        launchpad.sell(token, bought, 0, block.timestamp);
    }

    function test_sell_worksWhilePausedAndForAnyHolder() public {
        address token = _create(alice);
        uint256 bought = _buy(bob, token, 1 ether);
        vm.prank(owner);
        launchpad.setPaused(true);
        assertGt(_sell(bob, token, bought), 0);
        assertEq(DprkToken(token).balanceOf(bob), 0);
    }

    function test_sell_everythingRestoresCurve() public {
        address token = _create(alice);
        uint256 a = _buy(alice, token, 1.5 ether);
        uint256 b = _buy(bob, token, 0.7 ether);
        assertFalse(_state(token).graduated);
        _sell(alice, token, a);
        _sell(bob, token, b);
        IDprkLaunchpad.TokenState memory s = _state(token);
        assertEq(s.realTokenReserve, S);
        assertEq(s.virtualTokenReserve, Y0);
        // Only rounding dust (in the pool's favour) stays behind.
        assertLt(s.realBnbReserve, 10);
        assertEq(address(launchpad).balance, s.realBnbReserve + launchpad.accruedFees());
    }

    function test_quoteSell_moreThanCirculatingIsRejected() public {
        address token = _create(alice);
        _buy(bob, token, 1 ether);
        IDprkLaunchpad.TokenState memory s = _state(token);
        uint256 circulating = S - s.realTokenReserve;
        (uint256 out, uint256 fee) = launchpad.quoteSell(token, circulating);
        assertLe(out + fee, s.realBnbReserve);
        // Selling far more than exists would need another curve's BNB: the backstop catches it.
        vm.expectPartialRevert(IDprkLaunchpad.InsufficientRealBnbReserve.selector);
        launchpad.quoteSell(token, circulating * 10);
    }

    // ------------------------------------------------------------------------------------------- fees

    function test_claimFees_permissionless() public {
        address token = _create(alice);
        _buy(bob, token, 1 ether);
        _sell(bob, token, DprkToken(token).balanceOf(bob) / 2);
        uint256 fees = launchpad.accruedFees();
        assertGt(fees, 0);

        vm.expectEmit(true, false, false, true, address(launchpad));
        emit IDprkLaunchpad.FeesClaimed(feeRecipient, fees);
        vm.prank(mallory);
        assertEq(launchpad.claimFees(), fees);
        assertEq(feeRecipient.balance, fees);
        assertEq(launchpad.accruedFees(), 0);
        assertEq(address(launchpad).balance, _state(token).realBnbReserve);

        vm.expectRevert(IDprkLaunchpad.NoFeesAccrued.selector);
        launchpad.claimFees();
    }

    function test_claimFees_rejectingRecipientThenRotate() public {
        RejectBnb rejecter = new RejectBnb();
        vm.prank(owner);
        launchpad.setFeeRecipient(address(rejecter));
        address token = _create(alice);
        _buy(bob, token, 1 ether);

        vm.expectRevert(IDprkLaunchpad.BnbTransferFailed.selector);
        launchpad.claimFees();

        // Curves are unaffected while fees are stuck.
        _buy(carol, token, 1 ether);
        _sell(bob, token, DprkToken(token).balanceOf(bob));

        vm.prank(owner);
        launchpad.setFeeRecipient(feeRecipient);
        uint256 fees = launchpad.claimFees();
        assertEq(feeRecipient.balance, fees);
    }

    function test_claimFees_whilePaused() public {
        address token = _create(alice);
        _buy(bob, token, 1 ether);
        vm.prank(owner);
        launchpad.setPaused(true);
        assertGt(launchpad.claimFees(), 0);
    }

    // ------------------------------------------------------------------------------------------- owner

    function test_owner_setFeeRecipient() public {
        address next = makeAddr("next");
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        launchpad.setFeeRecipient(next);

        vm.prank(owner);
        vm.expectRevert(IDprkLaunchpad.InvalidConfiguration.selector);
        launchpad.setFeeRecipient(address(0));

        vm.expectEmit(true, true, false, false, address(launchpad));
        emit IDprkLaunchpad.FeeRecipientUpdated(feeRecipient, next);
        vm.prank(owner);
        launchpad.setFeeRecipient(next);
        assertEq(launchpad.feeRecipient(), next);
    }

    function test_owner_setPaused() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        launchpad.setPaused(true);

        vm.expectEmit(false, false, false, true, address(launchpad));
        emit IDprkLaunchpad.PausedSet(true);
        vm.prank(owner);
        launchpad.setPaused(true);
        assertTrue(launchpad.paused());

        vm.prank(owner);
        launchpad.setPaused(false);
        address token = _create(alice); // works again
        _buy(bob, token, 0.1 ether);
    }

    function test_owner_twoStepTransfer() public {
        address multisig = makeAddr("multisig");
        vm.prank(owner);
        launchpad.transferOwnership(multisig);
        assertEq(launchpad.owner(), owner);
        assertEq(launchpad.pendingOwner(), multisig);

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        launchpad.acceptOwnership();

        vm.prank(multisig);
        launchpad.acceptOwnership();
        assertEq(launchpad.owner(), multisig);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        launchpad.setPaused(true);
    }

    /// Graduation exists only inside a completing buy, so a pause holds it back. Sells and fee claims keep working.
    function test_owner_pauseBlocksGraduationButNotSells() public {
        address token = _create(alice);
        uint256 bobTokens = _buy(bob, token, 1 ether);
        uint256 gross = _grossToComplete(token);
        vm.prank(owner);
        launchpad.setPaused(true);

        vm.prank(carol);
        vm.expectRevert(IDprkLaunchpad.LaunchpadPaused.selector);
        launchpad.buy{value: gross}(token, 0, block.timestamp);
        assertFalse(_state(token).graduated);

        assertGt(_sell(bob, token, bobTokens / 2), 0);
        assertGt(launchpad.claimFees(), 0);

        vm.prank(owner);
        launchpad.setPaused(false);
        _buy(carol, token, _grossToComplete(token));
        assertTrue(_state(token).graduated);
    }

    /// Renouncing while paused would freeze creates, buys and graduations forever, so it reverts. Renouncing while
    /// unpaused works and leaves a launchpad that nobody can pause.
    function test_owner_renounceOnlyWhileUnpaused() public {
        address token = _create(alice);
        uint256 bobTokens = _buy(bob, token, _grossToComplete(token) - 1); // one wei short of completion
        assertFalse(_state(token).graduated);

        vm.startPrank(owner);
        launchpad.setPaused(true);
        vm.expectRevert(DprkLaunchpad.RenounceWhilePaused.selector);
        launchpad.renounceOwnership();
        vm.stopPrank();
        assertEq(launchpad.owner(), owner);

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        launchpad.renounceOwnership();

        vm.startPrank(owner);
        launchpad.setPaused(false);
        launchpad.renounceOwnership();
        vm.stopPrank();
        assertEq(launchpad.owner(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        launchpad.setPaused(true);

        // Nobody can pause any more: trading and graduation carry on.
        assertGt(_sell(bob, token, bobTokens / 2), 0);
        _buy(carol, token, _grossToComplete(token));
        assertTrue(_state(token).graduated);
    }

    // ------------------------------------------------------------------------------------------- views

    function test_views_unknownToken() public {
        address unknown = makeAddr("unknown");
        assertFalse(launchpad.isLaunchToken(unknown));
        bytes memory err = abi.encodeWithSelector(IDprkLaunchpad.UnknownToken.selector, unknown);
        vm.expectRevert(err);
        launchpad.getTokenState(unknown);
        vm.expectRevert(err);
        launchpad.getTokenInfo(unknown);
        vm.expectRevert(err);
        launchpad.progressBps(unknown);
        vm.expectRevert(err);
        launchpad.quoteBuy(unknown, 1 ether);
        vm.expectRevert(err);
        launchpad.quoteSell(unknown, 1 ether);
        vm.expectRevert(stdError.indexOOBError);
        launchpad.tokenAt(0);
    }

    function test_views_quotesOfZero() public {
        address token = _create(alice);
        (uint256 out, uint256 fee, uint256 accepted, uint256 refund) = launchpad.quoteBuy(token, 0);
        assertEq(out + fee + accepted + refund, 0);
        (out, fee) = launchpad.quoteSell(token, 0);
        assertEq(out + fee, 0);
    }

    function test_views_quoteCreateBuyEqualsFreshCurve() public {
        address token = _create(alice);
        for (uint256 v = 1; v < 100 ether; v = v * 7 + 3) {
            (uint256 a0, uint256 a1, uint256 a2, uint256 a3) = launchpad.quoteCreateBuy(v);
            (uint256 b0, uint256 b1, uint256 b2, uint256 b3) = launchpad.quoteBuy(token, v);
            assertEq(abi.encode(a0, a1, a2, a3), abi.encode(b0, b1, b2, b3));
        }
    }

    function test_views_canTrade() public view {
        assertTrue(launchpad.canTrade(alice));
        assertFalse(launchpad.canTrade(mallory));
    }

    function test_views_progressBps() public {
        address token = _create(alice);
        _buy(bob, token, 1 ether);
        IDprkLaunchpad.TokenState memory s = _state(token);
        assertEq(launchpad.progressBps(token), (S - s.realTokenReserve) * 10_000 / S);
        assertGt(launchpad.progressBps(token), 0);

        // One wei short of completion still reads below 10_000.
        uint256 gross = _grossToComplete(token);
        _buy(carol, token, gross - 1);
        assertFalse(_state(token).graduated);
        assertLt(launchpad.progressBps(token), 10_000);
    }

    function test_views_getTokenInfo() public {
        address token = _create(alice);
        IDprkLaunchpad.TokenInfo memory info = launchpad.getTokenInfo(token);
        assertEq(info.token, token);
        assertEq(info.name, NAME);
        assertEq(info.symbol, SYMBOL);
        assertEq(info.metadata, METADATA);
        assertEq(info.state.creator, alice);
        assertEq(info.state.realTokenReserve, S);
    }

    function test_views_getTokenInfosNewestFirstAndPaging() public {
        assertEq(launchpad.getTokenInfos(0, 10).length, 0);

        uint256 n = 105;
        address[] memory created = new address[](n);
        vm.startPrank(alice);
        for (uint256 i; i < n; ++i) {
            (created[i],) = launchpad.createToken(vm.toString(i), "T", "", 0, block.timestamp);
        }
        vm.stopPrank();
        assertEq(launchpad.tokenCount(), n);
        assertEq(launchpad.tokenAt(0), created[0]);
        assertEq(launchpad.tokenAt(n - 1), created[n - 1]);

        IDprkLaunchpad.TokenInfo[] memory page = launchpad.getTokenInfos(0, 1000);
        assertEq(page.length, 100); // capped
        assertEq(page[0].token, created[n - 1]); // newest first
        assertEq(page[0].name, "104");
        assertEq(page[99].token, created[5]);

        page = launchpad.getTokenInfos(100, 100);
        assertEq(page.length, 5);
        assertEq(page[0].token, created[4]);
        assertEq(page[4].token, created[0]);

        page = launchpad.getTokenInfos(3, 2);
        assertEq(page.length, 2);
        assertEq(page[0].token, created[n - 4]);
        assertEq(page[1].token, created[n - 5]);

        assertEq(launchpad.getTokenInfos(n, 10).length, 0);
        assertEq(launchpad.getTokenInfos(type(uint256).max, type(uint256).max).length, 0);
        assertEq(launchpad.getTokenInfos(0, 0).length, 0);
    }

    // ------------------------------------------------------------------------------------------- misc

    function test_rejectsPlainBnbTransfers() public {
        vm.prank(alice);
        (bool ok,) = address(launchpad).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_tokenDonationToLaunchpadIsInert() public {
        address token = _create(alice);
        uint256 bought = _buy(bob, token, 1 ether);
        IDprkLaunchpad.TokenState memory before = _state(token);
        vm.prank(bob);
        DprkToken(token).transfer(address(launchpad), bought / 2);
        IDprkLaunchpad.TokenState memory afterDonation = _state(token);
        assertEq(abi.encode(before), abi.encode(afterDonation)); // accounting ignores balanceOf
        _sell(bob, token, bought - bought / 2);
    }

    // ------------------------------------------------------------------------------------------- helpers

    function _expectInvalid(string memory name, string memory symbol, string memory metadata) internal {
        vm.expectRevert(IDprkLaunchpad.InvalidMetadata.selector);
        launchpad.createToken(name, symbol, metadata, 0, block.timestamp);
    }

    function _repeat(string memory unit, uint256 times) internal pure returns (string memory out) {
        for (uint256 i; i < times; ++i) {
            out = string.concat(out, unit);
        }
    }
}

contract RejectBnb {
    receive() external payable {
        revert("no thanks");
    }
}
