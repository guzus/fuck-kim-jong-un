// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {DprkLaunchpad} from "../../../src/launchpad/DprkLaunchpad.sol";
import {DprkToken} from "../../../src/launchpad/DprkToken.sol";
import {IDprkLaunchpad} from "../../../src/launchpad/interfaces/IDprkLaunchpad.sol";
import {IDprkToken} from "../../../src/launchpad/interfaces/IDprkToken.sol";
import {IPancakeV2Pair} from "../../../src/launchpad/interfaces/IPancakeV2.sol";
import {MockWBNB} from "../mocks/MockWBNB.sol";
import {MockPancakeFactory} from "../mocks/MockPancakeV2.sol";

/// @notice Drives the launchpad through random but valid sequences. Every action either succeeds or is skipped
/// up front, and expected failures are caught explicitly. Run with fail_on_revert = true, an unexpected revert
/// (for example a graduation that can't complete) fails the invariant run.
contract LaunchpadHandler is CommonBase, StdCheats, StdUtils {
    DprkLaunchpad public immutable launchpad;
    MockWBNB public immutable wbnb;
    MockPancakeFactory public immutable factory;
    address public immutable owner;

    address[] public actors; // certified
    address public immutable outsider; // never certified
    address[] public tokens;
    uint256 internal constant MAX_TOKENS = 8;
    uint256 internal constant LP_SUPPLY = 200_000_000e18;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ghosts
    mapping(address token => uint256) public lastK;
    uint256 public ghostFeesAccrued;
    uint256 public ghostFeesClaimed;
    bool public kDecreased;
    bool public roundTripProfit;
    bool public lockedTransferSucceeded;
    bool public completingBuyOverCharged;
    /// @dev Set if, at the moment a curve graduates, the pool lists below the final curve price or the LP isn't
    /// fully burned. (After graduation the pool is an ordinary market, so this is only checked at that moment.)
    bool public badGraduation;
    uint256 public graduations;
    mapping(address token => bool) internal _countedGraduation;
    mapping(bytes32 => uint256) public calls;

    constructor(
        DprkLaunchpad launchpad_,
        MockWBNB wbnb_,
        MockPancakeFactory factory_,
        address owner_,
        address[] memory actors_,
        address outsider_
    ) {
        launchpad = launchpad_;
        wbnb = wbnb_;
        factory = factory_;
        owner = owner_;
        actors = actors_;
        outsider = outsider_;
        for (uint256 i; i < actors_.length; ++i) {
            vm.deal(actors_[i], 1e30);
        }
    }

    // ------------------------------------------------------------------------------------------- views

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ------------------------------------------------------------------------------------------- actions

    function createToken(uint256 actorSeed, uint256 valueSeed, bool withBuy) external {
        if (tokens.length >= MAX_TOKENS || launchpad.paused()) return;
        address actor = _actor(actorSeed);
        uint256 value;
        uint256 fee;
        if (withBuy) {
            (,, uint256 gross,) = launchpad.quoteCreateBuy(type(uint256).max);
            value = _buySize(valueSeed, gross);
            uint256 out;
            (out, fee,,) = launchpad.quoteCreateBuy(value);
            if (out == 0) (value, fee) = (0, 0);
        }
        vm.prank(actor);
        (address token,) = launchpad.createToken{value: value}("Handler", "HDL", "{}", 0, block.timestamp);
        tokens.push(token);
        _approveAll(token);
        ghostFeesAccrued += fee;
        _afterTrade(token);
        calls["createToken"]++;
    }

    function buy(uint256 actorSeed, uint256 tokenSeed, uint256 valueSeed) external {
        (address token, bool ok) = _activeToken(tokenSeed);
        if (!ok || launchpad.paused()) return;
        address actor = _actor(actorSeed);
        uint256 gross = _grossToComplete(token);
        uint256 value = _buySize(valueSeed, gross);
        (uint256 quoted, uint256 fee, uint256 accepted, uint256 refund) = launchpad.quoteBuy(token, value);
        if (quoted == 0) return;
        if (accepted > value || accepted + refund != value) completingBuyOverCharged = true;

        uint256 balanceBefore = actor.balance;
        vm.prank(actor);
        uint256 out = launchpad.buy{value: value}(token, quoted, block.timestamp);
        if (out != quoted || balanceBefore - actor.balance != accepted) completingBuyOverCharged = true;
        ghostFeesAccrued += fee;
        _afterTrade(token);
        calls["buy"]++;
    }

    function sell(uint256 actorSeed, uint256 tokenSeed, uint256 bpsSeed) external {
        (address token, bool ok) = _activeToken(tokenSeed);
        if (!ok) return;
        address actor = _holder(actorSeed, token);
        uint256 amount = DprkToken(token).balanceOf(actor) * bound(bpsSeed, 1, 10_000) / 10_000;
        if (amount == 0) return;
        (uint256 quoted, uint256 fee) = launchpad.quoteSell(token, amount);
        if (quoted == 0) return;
        vm.prank(actor);
        launchpad.sell(token, amount, quoted, block.timestamp);
        ghostFeesAccrued += fee;
        _afterTrade(token);
        calls["sell"]++;
    }

    /// @dev Buys then immediately sells everything bought. Must never profit.
    function roundTrip(uint256 actorSeed, uint256 tokenSeed, uint256 valueSeed) external {
        (address token, bool ok) = _activeToken(tokenSeed);
        if (!ok || launchpad.paused()) return;
        address actor = _actor(actorSeed);
        uint256 gross = _grossToComplete(token);
        if (gross < 2) return;
        uint256 value = bound(valueSeed, 1, gross - 1);
        (uint256 quoted, uint256 buyFee,,) = launchpad.quoteBuy(token, value);
        if (quoted == 0) return;
        vm.startPrank(actor);
        uint256 got = launchpad.buy{value: value}(token, 0, block.timestamp);
        (uint256 back, uint256 sellFee) = launchpad.quoteSell(token, got);
        if (back != 0) back = launchpad.sell(token, got, 0, block.timestamp);
        else sellFee = 0;
        vm.stopPrank();
        if (back > value) roundTripProfit = true;
        ghostFeesAccrued += buyFee + sellFee;
        _afterTrade(token);
        calls["roundTrip"]++;
    }

    /// @dev Every actor sells its whole balance: holders can always exit.
    function everyoneExits(uint256 tokenSeed) external {
        (address token, bool ok) = _activeToken(tokenSeed);
        if (!ok) return;
        for (uint256 i; i < actors.length; ++i) {
            uint256 bal = DprkToken(token).balanceOf(actors[i]);
            if (bal == 0) continue;
            (uint256 quoted, uint256 fee) = launchpad.quoteSell(token, bal);
            if (quoted == 0) continue;
            vm.prank(actors[i]);
            launchpad.sell(token, bal, 0, block.timestamp);
            ghostFeesAccrued += fee;
        }
        _afterTrade(token);
        calls["everyoneExits"]++;
    }

    function transferToCertified(uint256 fromSeed, uint256 toSeed, uint256 tokenSeed, uint256 bpsSeed) external {
        if (tokens.length == 0) return;
        address token = tokens[tokenSeed % tokens.length];
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = DprkToken(token).balanceOf(from) * bound(bpsSeed, 0, 10_000) / 10_000;
        vm.prank(from);
        DprkToken(token).transfer(to, amount);
        calls["transferToCertified"]++;
    }

    /// @dev Pre-graduation, the outsider and the pair must never receive tokens.
    function transferToLocked(uint256 fromSeed, uint256 tokenSeed, bool toPair) external {
        if (tokens.length == 0) return;
        address token = tokens[tokenSeed % tokens.length];
        address from = _actor(fromSeed);
        uint256 bal = DprkToken(token).balanceOf(from);
        if (bal == 0) return;
        address to = toPair ? _pair(token) : outsider;
        bool graduated = DprkToken(token).graduated();
        vm.prank(from);
        try DprkToken(token).transfer(to, 1) {
            if (!graduated) lockedTransferSucceeded = true;
        } catch (bytes memory err) {
            if (graduated || bytes4(err) != IDprkToken.TransferLocked.selector) lockedTransferSucceeded = true;
        }
        calls["transferToLocked"]++;
    }

    /// @dev Griefing: (pre-)create the pair, donate WBNB, optionally sync.
    function donateWbnbToPair(uint256 tokenSeed, uint256 amountSeed, bool doSync) external {
        if (tokens.length == 0) return;
        address token = tokens[tokenSeed % tokens.length];
        address pair = _pair(token);
        uint256 amount = bound(amountSeed, 1, 50 ether);
        vm.deal(outsider, amount);
        vm.startPrank(outsider);
        wbnb.deposit{value: amount}();
        wbnb.transfer(pair, amount);
        vm.stopPrank();
        if (doSync) IPancakeV2Pair(pair).sync();
        calls["donateWbnbToPair"]++;
    }

    /// @dev A holder donates tokens straight to the launchpad (not a sell). Accounting must ignore it.
    function donateTokensToLaunchpad(uint256 fromSeed, uint256 tokenSeed, uint256 bpsSeed) external {
        if (tokens.length == 0) return;
        address token = tokens[tokenSeed % tokens.length];
        address from = _actor(fromSeed);
        uint256 amount = DprkToken(token).balanceOf(from) * bound(bpsSeed, 0, 1_000) / 10_000;
        vm.prank(from);
        DprkToken(token).transfer(address(launchpad), amount);
        calls["donateTokensToLaunchpad"]++;
    }

    function claimFees() external {
        uint256 fees = launchpad.accruedFees();
        if (fees == 0) return;
        launchpad.claimFees();
        ghostFeesClaimed += fees;
        calls["claimFees"]++;
    }

    /// @dev Pauses rarely and unpauses quickly, so most of a run trades.
    function togglePause(uint256 seed) external {
        bool paused = launchpad.paused(); // read before vm.prank, or the view call would consume the prank
        if (paused ? seed % 2 != 0 : seed % 10 != 0) return;
        vm.prank(owner);
        launchpad.setPaused(!paused);
        calls["togglePause"]++;
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 1 days));
    }

    // ------------------------------------------------------------------------------------------- helpers

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev First non-graduated token at or after `seed`.
    function _activeToken(uint256 seed) internal view returns (address token, bool ok) {
        uint256 n = tokens.length;
        for (uint256 i; i < n; ++i) {
            token = tokens[(seed % n + i) % n];
            if (!launchpad.getTokenState(token).graduated) return (token, true);
        }
        return (address(0), false);
    }

    /// @dev First actor at or after `seed` that holds `token` (falls back to the seeded actor).
    function _holder(uint256 seed, address token) internal view returns (address) {
        uint256 n = actors.length;
        for (uint256 i; i < n; ++i) {
            address a = actors[(seed % n + i) % n];
            if (DprkToken(token).balanceOf(a) != 0) return a;
        }
        return actors[seed % n];
    }

    function _grossToComplete(address token) internal view returns (uint256 gross) {
        (,, gross,) = launchpad.quoteBuy(token, type(uint256).max);
    }

    /// @dev Mostly small buys, sometimes one that completes the curve (usually with a refund).
    function _buySize(uint256 seed, uint256 gross) internal pure returns (uint256) {
        if (seed % 10 < 9) return bound(seed, 1, gross / 20 + 1);
        return bound(seed, gross / 2, gross + gross / 2);
    }

    function _pair(address token) internal returns (address pair) {
        pair = factory.getPair(token, address(wbnb));
        if (pair == address(0)) pair = factory.createPair(token, address(wbnb));
    }

    function _approveAll(address token) internal {
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            DprkToken(token).approve(address(launchpad), type(uint256).max);
        }
    }

    function _afterTrade(address token) internal {
        IDprkLaunchpad.TokenState memory s = launchpad.getTokenState(token);
        uint256 k = s.virtualBnbReserve * s.virtualTokenReserve;
        if (k < lastK[token]) kDecreased = true;
        lastK[token] = k;
        if (s.graduated && !_countedGraduation[token]) {
            _countedGraduation[token] = true;
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
}
