// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Ported from the independent review's regression suite (ReviewTokenRule).

import {KimJongUn} from "../../src/KimJongUn.sol";
import {DprkPass} from "../../src/launchpad/DprkPass.sol";
import {DprkLaunchpad} from "../../src/launchpad/DprkLaunchpad.sol";
import {DprkToken} from "../../src/launchpad/DprkToken.sol";
import {IDprkLaunchpad} from "../../src/launchpad/interfaces/IDprkLaunchpad.sol";
import {IDprkToken} from "../../src/launchpad/interfaces/IDprkToken.sol";
import {LaunchpadTestBase} from "./utils/LaunchpadTestBase.sol";

/// @dev A pass-holding custodian that buys for anyone and books balances internally. The token rule holds (only
/// the custodian holds tokens), but beneficial ownership is open to uncertified users.
contract OpenCustodian {
    DprkLaunchpad internal immutable pad;
    mapping(address token => mapping(address user => uint256)) public owed;

    constructor(DprkLaunchpad pad_) {
        pad = pad_;
    }

    function certify(KimJongUn kim, DprkPass pass) external {
        kim.pig();
        kim.fuck();
        pass.claim();
    }

    function buyFor(address token, address user) external payable {
        owed[token][user] += pad.buy{value: msg.value}(token, 0, block.timestamp);
    }

    function withdraw(address token) external {
        uint256 amount = owed[token][msg.sender];
        owed[token][msg.sender] = 0;
        DprkToken(token).transfer(msg.sender, amount);
    }
}

/// @dev A pass-holding contract with no receive(): it can buy (exact amount) but never sell to the curve itself.
contract NoReceiveHolder {
    function certify(KimJongUn kim, DprkPass pass) external {
        kim.pig();
        kim.fuck();
        pass.claim();
    }

    function buy(DprkLaunchpad pad, address token) external payable returns (uint256) {
        return pad.buy{value: msg.value}(token, 0, block.timestamp);
    }

    function sell(DprkLaunchpad pad, address token, uint256 amount) external returns (uint256) {
        DprkToken(token).approve(address(pad), amount);
        return pad.sell(token, amount, 0, block.timestamp);
    }

    function send(address token, address to, uint256 amount) external {
        DprkToken(token).transfer(to, amount);
    }
}

/// @notice The pre-graduation transfer rule from the holder's side: custody vs exposure, contract holders, and
/// every (sender, receiver) pairing.
contract DprkTokenHoldersTest is LaunchpadTestBase {
    /// Info: the gate restricts custody, not exposure. An uncertified wallet gets curve exposure through any
    /// certified contract; it simply can't take delivery before graduation.
    function test_gateRestrictsCustodyNotExposure() public {
        OpenCustodian custodian = new OpenCustodian(launchpad);
        custodian.certify(kimJongUn, pass);
        address token = _create(alice);

        vm.prank(mallory); // never certified
        custodian.buyFor{value: 1 ether}(token, mallory);
        uint256 owed = custodian.owed(token, mallory);
        assertGt(owed, 0);

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IDprkToken.TransferLocked.selector, address(custodian), mallory));
        custodian.withdraw(token);

        _buy(bob, token, _grossToComplete(token));
        vm.prank(mallory);
        custodian.withdraw(token);
        assertEq(DprkToken(token).balanceOf(mallory), owed);
    }

    /// Info: `sell` always pays msg.sender. A certified contract without receive() can't sell or take a refund;
    /// its tokens are not trapped (it can move them to any other pass holder), but it must do so.
    function test_contractWithoutReceiveMustRouteThroughAnotherHolder() public {
        NoReceiveHolder holder = new NoReceiveHolder();
        holder.certify(kimJongUn, pass);
        address token = _create(alice);
        vm.deal(address(this), 10 ether);
        uint256 got = holder.buy{value: 1 ether}(launchpad, token);

        vm.expectRevert(IDprkLaunchpad.BnbTransferFailed.selector);
        holder.sell(launchpad, token, got);

        holder.send(token, bob, got);
        assertGt(_sell(bob, token, got), 0);

        // A completing buy with any refund also reverts for it; only an exact-gross buy works.
        uint256 gross = _grossToComplete(token);
        vm.deal(address(this), gross + 1);
        vm.expectRevert(IDprkLaunchpad.BnbTransferFailed.selector);
        holder.buy{value: gross + 1}(launchpad, token);
        holder.buy{value: gross}(launchpad, token);
        assertTrue(_state(token).graduated);
    }

    /// Fuzz the rule against every (sender kind, receiver kind) pair before graduation, including the pair, the
    /// launchpad, dEaD, uncertified and certified addresses, and transferFrom by an uncertified spender.
    function testFuzz_ruleMatrix(uint8 receiverKind, bool viaTransferFrom, uint96 amountSeed) public {
        address token = _create(alice);
        uint256 held = _buy(bob, token, 1 ether);
        address pair = factory.createPair(token, address(wbnb));
        address[5] memory receivers = [pair, mallory, DEAD, carol, address(launchpad)];
        address to = receivers[receiverKind % 5];
        bool allowed = to == carol || to == address(launchpad);
        uint256 amount = uint256(amountSeed) % (held + 1);

        if (viaTransferFrom) {
            vm.prank(bob);
            DprkToken(token).approve(mallory, amount);
            vm.prank(mallory);
            if (!allowed) vm.expectRevert(abi.encodeWithSelector(IDprkToken.TransferLocked.selector, bob, to));
            DprkToken(token).transferFrom(bob, to, amount);
        } else {
            vm.prank(bob);
            if (!allowed) vm.expectRevert(abi.encodeWithSelector(IDprkToken.TransferLocked.selector, bob, to));
            DprkToken(token).transfer(to, amount);
        }
        assertEq(DprkToken(token).balanceOf(pair), 0);
        assertEq(DprkToken(token).balanceOf(mallory), 0);
        // Whatever happened, bob (or carol) can still exit through the curve.
        uint256 left = DprkToken(token).balanceOf(bob);
        (uint256 q,) = launchpad.quoteSell(token, left);
        if (q != 0) assertEq(_sell(bob, token, left), q);
    }
}
