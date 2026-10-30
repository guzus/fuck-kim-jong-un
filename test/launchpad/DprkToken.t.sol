// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {DprkToken} from "../../src/launchpad/DprkToken.sol";
import {IDprkToken} from "../../src/launchpad/interfaces/IDprkToken.sol";
import {LaunchpadTestBase} from "./utils/LaunchpadTestBase.sol";

/// @notice Transfer-rule tests. Here the test contract plays the launchpad: it deploys the token and gets the
/// whole supply.
contract DprkTokenTest is LaunchpadTestBase {
    DprkToken internal token;
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    function setUp() public override {
        super.setUp();
        token = new DprkToken(NAME, SYMBOL, METADATA, alice, address(pass), SUPPLY);
    }

    function test_constructor() public view {
        assertEq(token.name(), NAME);
        assertEq(token.symbol(), SYMBOL);
        assertEq(token.decimals(), 18);
        assertEq(token.metadata(), METADATA);
        assertEq(token.creator(), alice);
        assertEq(token.launchpad(), address(this));
        assertEq(token.pass(), address(pass));
        assertFalse(token.graduated());
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_launchpadCanSendToAnyone() public {
        token.transfer(mallory, 1); // from == launchpad
        assertEq(token.balanceOf(mallory), 1);
    }

    function test_certifiedReceiverAllowed() public {
        token.transfer(alice, 100);
        vm.prank(alice);
        token.transfer(bob, 40);
        assertEq(token.balanceOf(bob), 40);
    }

    function test_uncertifiedReceiverLocked() public {
        token.transfer(alice, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDprkToken.TransferLocked.selector, alice, mallory));
        token.transfer(mallory, 1);
    }

    function test_zeroValueToUncertifiedLocked() public {
        token.transfer(alice, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDprkToken.TransferLocked.selector, alice, mallory));
        token.transfer(mallory, 0);
    }

    function test_anyoneCanSendToLaunchpad() public {
        // Even an uncertified sender: `to == launchpad` short-circuits before the pass is consulted.
        token.transfer(mallory, 10);
        vm.prank(mallory);
        token.transfer(address(this), 10);
        assertEq(token.balanceOf(mallory), 0);
    }

    function test_thirdPartyTransferFromFollowsReceiverRule() public {
        token.transfer(alice, 100);
        vm.prank(alice);
        token.approve(mallory, type(uint256).max); // approvals themselves are unrestricted

        vm.startPrank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IDprkToken.TransferLocked.selector, alice, mallory));
        token.transferFrom(alice, mallory, 1);
        token.transferFrom(alice, bob, 30); // certified receiver: fine, whoever the spender is
        token.transferFrom(alice, address(this), 30); // to launchpad: fine
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 30);
        assertEq(token.balanceOf(alice), 40);
    }

    function test_certificationIsCheckedAtReceiveTime() public {
        address dave = makeAddr("dave");
        token.transfer(alice, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDprkToken.TransferLocked.selector, alice, dave));
        token.transfer(dave, 1);

        _certify(dave);
        vm.prank(alice);
        token.transfer(dave, 1);
        assertEq(token.balanceOf(dave), 1);
    }

    function test_burnAddressesLocked() public {
        token.transfer(alice, 100);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDprkToken.TransferLocked.selector, alice, DEAD));
        token.transfer(DEAD, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.stopPrank();
    }

    function test_markGraduated_onlyLaunchpad() public {
        vm.prank(alice);
        vm.expectRevert(IDprkToken.OnlyLaunchpad.selector);
        token.markGraduated();
        vm.prank(token.creator());
        vm.expectRevert(IDprkToken.OnlyLaunchpad.selector);
        token.markGraduated();
    }

    function test_afterGraduationPlainErc20() public {
        token.transfer(alice, 100);
        token.markGraduated();
        assertTrue(token.graduated());
        vm.prank(alice);
        token.transfer(mallory, 60);
        vm.prank(mallory);
        token.transfer(makeAddr("anyone"), 10);
        assertEq(token.balanceOf(mallory), 50);
        token.markGraduated(); // idempotent
    }

    function testFuzz_ruleMatchesSpec(address to, bool certify, uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.assume(to != address(0) && to != address(this) && to != alice);
        vm.assume(to.code.length == 0);
        if (certify && !pass.isCertified(to)) _certify(to);
        bool allowed = pass.isCertified(to);

        token.transfer(alice, amount);
        vm.prank(alice);
        if (!allowed) vm.expectRevert(abi.encodeWithSelector(IDprkToken.TransferLocked.selector, alice, to));
        token.transfer(to, amount);
        assertEq(token.balanceOf(to), allowed ? amount : 0);
    }
}

/// @notice The same rule exercised through the real launchpad.
contract DprkTokenThroughLaunchpadTest is LaunchpadTestBase {
    function test_buyerAndPairRule() public {
        address token = _create(alice);
        _buy(bob, token, 0.1 ether);
        uint256 bal = DprkToken(token).balanceOf(bob);
        assertGt(bal, 0);

        // Pre-create the PancakeSwap pair: it can't receive curve tokens.
        address pair = factory.createPair(token, address(wbnb));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IDprkToken.TransferLocked.selector, bob, pair));
        DprkToken(token).transfer(pair, 1);

        // Bob can always sell, and can move tokens to another pass holder.
        vm.prank(bob);
        DprkToken(token).transfer(carol, bal / 2);
        _sell(carol, token, bal / 2);
        _sell(bob, token, bal - bal / 2);
        assertEq(DprkToken(token).balanceOf(bob), 0);
        assertEq(DprkToken(token).balanceOf(carol), 0);
    }

    function test_tokenMetadataWiring() public {
        address token = _create(alice);
        assertEq(DprkToken(token).launchpad(), address(launchpad));
        assertEq(DprkToken(token).pass(), address(pass));
        assertEq(DprkToken(token).creator(), alice);
        assertEq(DprkToken(token).metadata(), METADATA);
        assertEq(DprkToken(token).totalSupply(), launchpad.TOTAL_SUPPLY());
        assertEq(DprkToken(token).balanceOf(address(launchpad)), launchpad.TOTAL_SUPPLY());
    }
}
