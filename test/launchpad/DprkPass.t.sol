// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {KimJongUn} from "../../src/KimJongUn.sol";
import {DprkPass} from "../../src/launchpad/DprkPass.sol";
import {IDprkPass, IERC5192} from "../../src/launchpad/interfaces/IDprkPass.sol";
import {Base64Decode} from "./utils/Base64Decode.sol";

contract DprkPassTest is Test {
    KimJongUn internal kimJongUn;
    DprkPass internal pass;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        kimJongUn = new KimJongUn();
        pass = new DprkPass(address(kimJongUn), "DPRK.FUN Not-Lazarus Pass", "NOTLAZ");
    }

    function _insult(address who, bool doPig, bool doFuck) internal {
        vm.startPrank(who);
        if (doPig) kimJongUn.pig();
        if (doFuck) kimJongUn.fuck();
        vm.stopPrank();
    }

    function _claim(address who) internal returns (uint256 id) {
        _insult(who, true, true);
        vm.prank(who);
        id = pass.claim();
    }

    // ------------------------------------------------------------------------------------------- config

    function test_constructor() public view {
        assertEq(pass.name(), "DPRK.FUN Not-Lazarus Pass");
        assertEq(pass.symbol(), "NOTLAZ");
        assertEq(pass.kimJongUn(), address(kimJongUn));
        assertEq(pass.totalClaimed(), 0);
    }

    function test_constructor_rejectsRegistryWithoutCode() public {
        vm.expectRevert(DprkPass.InvalidRegistry.selector);
        new DprkPass(address(0), "n", "s");
        vm.expectRevert(DprkPass.InvalidRegistry.selector);
        new DprkPass(makeAddr("eoa"), "n", "s");
    }

    // ------------------------------------------------------------------------------------------- claim gate

    function test_claim_revertsWithoutInsults() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDprkPass.NotPiggedAndFucked.selector, alice));
        pass.claim();
    }

    function test_claim_revertsAfterPigOnly() public {
        _insult(alice, true, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDprkPass.NotPiggedAndFucked.selector, alice));
        pass.claim();
    }

    function test_claim_revertsAfterFuckOnly() public {
        _insult(alice, false, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDprkPass.NotPiggedAndFucked.selector, alice));
        pass.claim();
    }

    function test_claim_mintsLockedPassAfterPigAndFuck() public {
        _insult(alice, true, true);
        vm.expectEmit(address(pass));
        emit IERC5192.Locked(1);
        vm.expectEmit(address(pass));
        emit IDprkPass.PassClaimed(alice, 1);
        vm.prank(alice);
        uint256 id = pass.claim();

        assertEq(id, 1);
        assertEq(pass.ownerOf(1), alice);
        assertEq(pass.balanceOf(alice), 1);
        assertEq(pass.passOf(alice), 1);
        assertTrue(pass.isCertified(alice));
        assertTrue(pass.locked(1));
        assertEq(pass.totalClaimed(), 1);
    }

    function test_claim_insultOrderDoesNotMatter() public {
        _insult(alice, false, true);
        _insult(alice, true, false);
        vm.prank(alice);
        assertEq(pass.claim(), 1);
    }

    function test_claim_idsIncrementFromOne() public {
        assertEq(_claim(alice), 1);
        assertEq(_claim(bob), 2);
        address carol = makeAddr("carol");
        assertEq(_claim(carol), 3);
        assertEq(pass.totalClaimed(), 3);
        assertEq(pass.passOf(bob), 2);
    }

    function test_claim_onePerAddress() public {
        _claim(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDprkPass.AlreadyCertified.selector, alice));
        pass.claim();
    }

    function test_claim_contractCanClaim() public {
        PassClaimer claimer = new PassClaimer(kimJongUn, pass);
        uint256 id = claimer.run();
        assertEq(pass.ownerOf(id), address(claimer));
        assertTrue(pass.isCertified(address(claimer)));
    }

    function test_uncertifiedViews() public view {
        assertFalse(pass.isCertified(alice));
        assertEq(pass.passOf(alice), 0);
    }

    // ------------------------------------------------------------------------------------------- soulbound

    function test_soulbound_transfersAndApprovalsRevert() public {
        _claim(alice);
        vm.startPrank(alice);
        vm.expectRevert(IDprkPass.Soulbound.selector);
        pass.transferFrom(alice, bob, 1);
        vm.expectRevert(IDprkPass.Soulbound.selector);
        pass.safeTransferFrom(alice, bob, 1);
        vm.expectRevert(IDprkPass.Soulbound.selector);
        pass.safeTransferFrom(alice, bob, 1, "");
        vm.expectRevert(IDprkPass.Soulbound.selector);
        pass.approve(bob, 1);
        vm.expectRevert(IDprkPass.Soulbound.selector);
        pass.setApprovalForAll(bob, true);
        vm.stopPrank();

        assertEq(pass.ownerOf(1), alice);
        assertEq(pass.getApproved(1), address(0));
        assertFalse(pass.isApprovedForAll(alice, bob));
    }

    function test_soulbound_approvalsAlwaysRevert(address caller, address to, uint256 id, bool approved) public {
        _claim(alice);
        vm.startPrank(caller);
        vm.expectRevert(IDprkPass.Soulbound.selector);
        pass.approve(to, id);
        vm.expectRevert(IDprkPass.Soulbound.selector);
        pass.setApprovalForAll(to, approved);
        vm.stopPrank();
    }

    function test_soulbound_existingPassNeverMoves(address caller, address from, address to) public {
        vm.assume(to != address(0));
        uint256 id = _claim(alice);
        vm.startPrank(caller);
        vm.expectRevert(IDprkPass.Soulbound.selector);
        pass.transferFrom(from, to, id);
        vm.expectRevert(IDprkPass.Soulbound.selector);
        pass.safeTransferFrom(from, to, id);
        vm.expectRevert(IDprkPass.Soulbound.selector);
        pass.safeTransferFrom(from, to, id, "0x1234");
        vm.stopPrank();
        assertEq(pass.ownerOf(id), alice);
    }

    function test_soulbound_nonPassesUseStandardErrors() public {
        // No pass to move: ERC-721's own checks answer first.
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 42));
        pass.transferFrom(alice, bob, 42);
        _claim(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        pass.transferFrom(alice, address(0), 1);
    }

    function test_locked_revertsForUnknownToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        pass.locked(1);
    }

    function test_supportsInterface() public view {
        assertTrue(pass.supportsInterface(0xb45a3c0e)); // ERC-5192
        assertTrue(pass.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(pass.supportsInterface(0x5b5e139f)); // ERC-721 metadata
        assertTrue(pass.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(pass.supportsInterface(0xffffffff));
        assertFalse(pass.supportsInterface(0x780e9d63)); // ERC-721 enumerable (not implemented)
        assertEq(type(IERC5192).interfaceId, bytes4(0xb45a3c0e));
    }

    // ------------------------------------------------------------------------------------------- tokenURI

    function test_tokenURI_revertsForUnknownToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 7));
        pass.tokenURI(7);
    }

    function test_tokenURI_decodesToValidJsonAndSvg() public {
        _claim(bob); // id 1
        uint256 id = _claim(alice); // id 2
        (string memory json, string memory svg) = _decode(pass.tokenURI(id));

        // vm.parseJson* reverts on malformed JSON, so these double as a validity check.
        assertEq(vm.parseJsonString(json, ".name"), "DPRK.FUN Not-Lazarus Pass #2");
        assertTrue(vm.contains(vm.parseJsonString(json, ".description"), unicode"김정은 개새끼"));
        assertEq(vm.parseJsonString(json, ".external_url"), "https://dprk.fun/launchpad");
        assertEq(vm.parseJsonString(json, ".attributes[0].trait_type"), "Holder");
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), Strings.toHexString(alice));
        assertEq(vm.parseJsonString(json, ".attributes[1].trait_type"), "pig()");
        assertEq(vm.parseJsonString(json, ".attributes[1].value"), unicode"✓");
        assertEq(vm.parseJsonString(json, ".attributes[2].trait_type"), "fuck()");
        assertEq(vm.parseJsonString(json, ".attributes[3].value"), "No");
        assertEq(vm.parseJsonString(json, ".attributes[4].value"), "Yes");
        assertEq(vm.parseJsonUint(json, ".attributes[5].value"), 2);
        assertEq(vm.parseJsonKeys(json, "$").length, 5);

        assertTrue(vm.contains(svg, '<svg xmlns="http://www.w3.org/2000/svg"'));
        assertTrue(vm.contains(svg, "DPRK.FUN"));
        assertTrue(vm.contains(svg, "NOT-LAZARUS PASS"));
        assertTrue(vm.contains(svg, unicode"김정은 개새끼"));
        assertTrue(vm.contains(svg, unicode"pig() ✓ fuck() ✓"));
        assertTrue(vm.contains(svg, ">#2</text>"));
        string memory hexAlice = Strings.toHexString(alice);
        string memory shortAlice = string.concat(_slice(hexAlice, 0, 6), unicode"…", _slice(hexAlice, 38, 42));
        assertTrue(vm.contains(svg, string.concat(">", shortAlice, "</text></svg>")));
        assertFalse(vm.contains(svg, hexAlice)); // only the short form is drawn
    }

    function test_tokenURI_escapesHostileCollectionName() public {
        string memory hostile = string(abi.encodePacked('Pass "quoted" \\ back', bytes1(0x0a), "line", bytes1(0x01)));
        DprkPass weird = new DprkPass(address(kimJongUn), hostile, "W");
        _insult(alice, true, true);
        vm.prank(alice);
        weird.claim();
        (string memory json,) = _decode(weird.tokenURI(1));
        assertEq(vm.parseJsonString(json, ".name"), string.concat(hostile, " #1"));
    }

    function test_tokenURI_multiDigitIds() public {
        for (uint256 i; i < 12; ++i) {
            _claim(address(uint160(0x1000 + i)));
        }
        (string memory json, string memory svg) = _decode(pass.tokenURI(12));
        assertEq(vm.parseJsonUint(json, ".attributes[5].value"), 12);
        assertTrue(vm.contains(svg, ">#12</text>"));
    }

    // ------------------------------------------------------------------------------------------- helpers

    function _decode(string memory uri) internal pure returns (string memory json, string memory svg) {
        json = string(Base64Decode.decode(Base64Decode.stripPrefix(uri, "data:application/json;base64,")));
        string memory image = vm.parseJsonString(json, ".image");
        svg = string(Base64Decode.decode(Base64Decode.stripPrefix(image, "data:image/svg+xml;base64,")));
    }

    function _slice(string memory s, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory r = new bytes(end - start);
        for (uint256 i = start; i < end; ++i) {
            r[i - start] = b[i];
        }
        return string(r);
    }
}

/// @dev A contract holder: insults Kim and claims in one call.
contract PassClaimer {
    KimJongUn internal immutable kim;
    DprkPass internal immutable pass;

    constructor(KimJongUn kim_, DprkPass pass_) {
        kim = kim_;
        pass = pass_;
    }

    function run() external returns (uint256) {
        kim.pig();
        kim.fuck();
        return pass.claim();
    }
}
