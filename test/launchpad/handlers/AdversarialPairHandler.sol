// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Ported from the independent review's regression suite (ReviewAdversarialInvariant).

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {DprkLaunchpad} from "../../../src/launchpad/DprkLaunchpad.sol";
import {DprkToken} from "../../../src/launchpad/DprkToken.sol";
import {IDprkLaunchpad} from "../../../src/launchpad/interfaces/IDprkLaunchpad.sol";
import {IPancakeV2Pair} from "../../../src/launchpad/interfaces/IPancakeV2.sol";
import {MockWBNB} from "../mocks/MockWBNB.sol";
import {MockPancakeFactory, MockPancakePair} from "../mocks/MockPancakeV2.sol";

/// @notice Adversarial handler: certified traders plus an uncertified griefer who pre-creates pairs (including for
/// not-yet-deployed token addresses), donates and syncs WBNB, skims, tries to mint/burn/swap on the pair, toggles
/// PancakeSwap's protocol fee, and forces BNB into the launchpad. Completing buys (with refunds) are frequent.
/// With fail_on_revert = true, any graduation that reverts fails the campaign.
contract AdversarialPairHandler is CommonBase, StdCheats, StdUtils {
    DprkLaunchpad public immutable launchpad;
    MockWBNB public immutable wbnb;
    MockPancakeFactory public immutable factory;
    address public immutable griefer; // never certified
    address[] public actors; // certified
    address[] public tokens;

    uint256 internal constant MAX_TOKENS = 6;
    uint256 internal constant LP_SUPPLY = 200_000_000e18;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    bool public pairGriefSucceeded;
    bool public badGraduation;
    uint256 public graduations;
    uint256 public completingBuys;
    uint256 public forcedBnb;
    uint256 public preGraduationGriefCalls;
    uint256 public gradsIntoPrecreatedPair;
    uint256 public gradsIntoSyncedDonation;
    uint256 public gradsWithFeeOn;
    mapping(address token => bool) internal _counted;

    constructor(
        DprkLaunchpad launchpad_,
        MockWBNB wbnb_,
        MockPancakeFactory factory_,
        address[] memory actors_,
        address griefer_
    ) {
        launchpad = launchpad_;
        wbnb = wbnb_;
        factory = factory_;
        actors = actors_;
        griefer = griefer_;
        for (uint256 i; i < actors_.length; ++i) {
            vm.deal(actors_[i], 1e30);
        }
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    // ------------------------------------------------------------------------------------------- traders

    function createToken(uint256 actorSeed, uint256 valueSeed) external {
        if (tokens.length >= MAX_TOKENS) return;
        address actor = actors[actorSeed % actors.length];
        (,, uint256 gross,) = launchpad.quoteCreateBuy(type(uint256).max);
        uint256 value = valueSeed % 4 == 0 ? 0 : _size(valueSeed, gross);
        (uint256 out,,,) = launchpad.quoteCreateBuy(value);
        if (out == 0) value = 0;
        vm.prank(actor);
        (address token,) = launchpad.createToken{value: value}("Adv", "ADV", "{}", 0, block.timestamp);
        tokens.push(token);
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            DprkToken(token).approve(address(launchpad), type(uint256).max);
        }
        _afterTrade(token);
    }

    function buy(uint256 actorSeed, uint256 tokenSeed, uint256 valueSeed) external {
        (address token, bool ok) = _active(tokenSeed);
        if (!ok) return;
        address actor = actors[actorSeed % actors.length];
        (,, uint256 gross,) = launchpad.quoteBuy(token, type(uint256).max);
        uint256 value = _size(valueSeed, gross);
        (uint256 q,,,) = launchpad.quoteBuy(token, value);
        if (q == 0) return;
        if (value >= gross) {
            completingBuys++;
            _countGraduationConditions(token);
        }
        vm.prank(actor);
        launchpad.buy{value: value}(token, q, block.timestamp); // a graduation revert fails the run
        _afterTrade(token);
    }

    function sell(uint256 actorSeed, uint256 tokenSeed, uint256 bpsSeed) external {
        (address token, bool ok) = _active(tokenSeed);
        if (!ok) return;
        address actor = actors[actorSeed % actors.length];
        uint256 amount = DprkToken(token).balanceOf(actor) * bound(bpsSeed, 1, 10_000) / 10_000;
        if (amount == 0) return;
        (uint256 q,) = launchpad.quoteSell(token, amount);
        if (q == 0) return;
        vm.prank(actor);
        launchpad.sell(token, amount, q, block.timestamp);
        _afterTrade(token);
    }

    // ------------------------------------------------------------------------------------------- griefer

    /// Pre-create the pair for the next token the launchpad will deploy, and donate to it.
    function griefPredictedPair(uint256 amountSeed) external {
        address predicted = vm.computeCreateAddress(address(launchpad), vm.getNonce(address(launchpad)));
        if (factory.getPair(predicted, address(wbnb)) == address(0)) factory.createPair(predicted, address(wbnb));
        _donate(factory.getPair(predicted, address(wbnb)), amountSeed);
    }

    function griefPair(uint256 tokenSeed, uint256 actionSeed, uint256 amountSeed) external {
        if (tokens.length == 0) return;
        // Prefer a curve that hasn't graduated yet (that is where griefing matters); fall back to any token.
        (address token, bool active) = _active(tokenSeed);
        if (!active) token = tokens[tokenSeed % tokens.length];
        address pair = factory.getPair(token, address(wbnb));
        if (pair == address(0)) pair = factory.createPair(token, address(wbnb));
        bool pre = !DprkToken(token).graduated();
        if (pre) preGraduationGriefCalls++;
        uint256 action = actionSeed % 8;

        if (action == 0) {
            _donate(pair, amountSeed);
        } else if (action == 1) {
            IPancakeV2Pair(pair).sync();
        } else if (action == 2) {
            IPancakeV2Pair(pair).skim(actors[amountSeed % actors.length]); // to a pass holder: always fine
        } else if (action == 3) {
            vm.prank(griefer);
            try IPancakeV2Pair(pair).mint(griefer) {
                if (pre) pairGriefSucceeded = true;
            } catch {}
        } else if (action == 4) {
            vm.prank(griefer);
            try IPancakeV2Pair(pair).burn(griefer) {
                if (pre) pairGriefSucceeded = true;
            } catch {}
        } else if (action == 5) {
            vm.prank(griefer);
            try MockPancakePair(pair).swap(amountSeed % 2, 1 - amountSeed % 2, griefer, "") {
                if (pre) pairGriefSucceeded = true;
            } catch {}
        } else if (action == 6) {
            // A pass holder tries to seed the token side.
            address holder = actors[amountSeed % actors.length];
            uint256 bal = DprkToken(token).balanceOf(holder);
            vm.prank(holder);
            try DprkToken(token).transfer(pair, bal % 3 == 0 ? 0 : bal / 3) {
                if (pre) pairGriefSucceeded = true;
            } catch {}
        } else {
            factory.setFeeTo(factory.feeTo() == address(0) ? makeAddr("pancakeTreasury") : address(0));
        }
    }

    function forceBnb(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 10 ether);
        vm.deal(address(launchpad), address(launchpad).balance + amount); // stands in for SELFDESTRUCT
        forcedBnb += amount;
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 1 days));
    }

    // ------------------------------------------------------------------------------------------- helpers

    function _donate(address pair, uint256 amountSeed) internal {
        uint256 amount = bound(amountSeed, 1, 1_000_000 ether);
        vm.deal(griefer, amount);
        vm.startPrank(griefer);
        wbnb.deposit{value: amount}();
        wbnb.transfer(pair, amount);
        vm.stopPrank();
    }

    /// @dev 8% completing (with up to +50% refund), otherwise log-uniform small buys.
    function _size(uint256 seed, uint256 gross) internal pure returns (uint256) {
        if (seed % 100 < 8) return bound(seed >> 8, gross, gross + gross / 2);
        return bound(seed >> 8, 1, (gross >> ((seed >> 4) % 40)) + 1);
    }

    function _countGraduationConditions(address token) internal {
        address pair = factory.getPair(token, address(wbnb));
        if (pair == address(0)) return;
        gradsIntoPrecreatedPair++;
        (uint112 r0, uint112 r1,) = IPancakeV2Pair(pair).getReserves();
        if (r0 != 0 || r1 != 0) gradsIntoSyncedDonation++;
        if (factory.feeTo() != address(0)) gradsWithFeeOn++;
    }

    function _active(uint256 seed) internal view returns (address token, bool ok) {
        uint256 n = tokens.length;
        for (uint256 i; i < n; ++i) {
            token = tokens[(seed % n + i) % n];
            if (!launchpad.getTokenState(token).graduated) return (token, true);
        }
        return (address(0), false);
    }

    function _afterTrade(address token) internal {
        IDprkLaunchpad.TokenState memory s = launchpad.getTokenState(token);
        if (!s.graduated || _counted[token]) return;
        _counted[token] = true;
        graduations++;
        IPancakeV2Pair pair = IPancakeV2Pair(s.pair);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rb, uint256 rt) = pair.token0() == token ? (uint256(r1), uint256(r0)) : (uint256(r0), uint256(r1));
        if (
            rt != LP_SUPPLY || rb < s.realBnbReserve || rb * s.virtualTokenReserve < s.virtualBnbReserve * rt
                || pair.totalSupply() != pair.balanceOf(DEAD) + 1000 || pair.balanceOf(DEAD) == 0
        ) badGraduation = true;
    }
}

