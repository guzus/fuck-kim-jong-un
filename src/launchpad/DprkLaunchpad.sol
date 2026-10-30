// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {DprkToken} from "./DprkToken.sol";
import {IDprkLaunchpad} from "./interfaces/IDprkLaunchpad.sol";
import {IDprkPass} from "./interfaces/IDprkPass.sol";
import {IDprkToken} from "./interfaces/IDprkToken.sol";
import {IPancakeV2Factory, IPancakeV2Pair, IWBNB} from "./interfaces/IPancakeV2.sol";

/// @title DPRK.FUN launchpad
/// @notice Pass-gated bonding-curve launchpad. See docs/BSC_LAUNCHPAD.md.
///
/// Curve. Each token has a virtual constant-product pool `x * y = k` with
///   x = virtualBnbReserve   = realBnbReserve   + initialVirtualBnbReserve        (V0)
///   y = virtualTokenReserve = realTokenReserve + FINAL_VIRTUAL_TOKEN_RESERVE   (y0 - CURVE_SUPPLY)
/// Only the two real reserves are stored, so both offset invariants hold by construction. With
/// y0 = CURVE_SUPPLY^2 / (CURVE_SUPPLY - LP_SUPPLY), the final curve price equals the PancakeSwap listing price
/// realBnb / LP_SUPPLY.
///
/// Rounding. Curve outputs round down and a completing buy's required input rounds up, so `k` never decreases.
/// Fees round up: `net = floor(gross * (10_000 - feeBps) / 10_000)`. That one definition matters, because it makes
/// "net(gross) buys the whole remainder" exactly equivalent to "gross >= grossRequired". So the completing path
/// never charges more than msg.value, and a non-completing buy can never reach the remainder.
///
/// Graduation happens only inline, in the completing buy, so pausing buys also pauses graduation. Selling is
/// never paused. The launchpad mints the pair directly (never the router). The token's transfer rule keeps the
/// pair from holding tokens before that, so nobody else can hold LP shares first. Donated WBNB (synced or not)
/// only raises the listing price. The LP minted at graduation is sent to 0x...dEaD (burned). That doesn't lock
/// 100% of the pool forever: when PancakeSwap's `feeTo` is set, the pair later mints protocol-fee LP to it out of
/// swap-fee growth, and that LP can be withdrawn.
///
/// Post-graduation state is frozen: realTokenReserve = 0, and realBnbReserve stays at the BNB that went into the
/// pair. That BNB is no longer held by this contract. The virtual reserves are the final curve reserves, so
/// `virtualBnbReserve / virtualTokenReserve` reads as the listing price. The solvency invariant is
/// `address(this).balance >= accruedFees + sum(realBnbReserve of curves that have not graduated)`.
///
/// Admin trust (Ownable2Step owner): pause/unpause createToken and buy (which also holds back graduation), and set
/// the fee recipient, which also redirects fees that have accrued but not been claimed. The owner can't touch
/// curve reserves, fees already paid out, or sells. Renouncing is only possible while unpaused, so a pause can
/// never become permanent.
///
/// Integrators: anyone can deploy look-alike `DprkToken` contracts. Trust a token only if
/// `isLaunchToken(token)` is true on this launchpad.
contract DprkLaunchpad is IDprkLaunchpad, Ownable2Step, ReentrancyGuard {
    // ------------------------------------------------------------------------------------------------ constants

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant CURVE_SUPPLY = 800_000_000e18;
    uint256 public constant LP_SUPPLY = TOTAL_SUPPLY - CURVE_SUPPLY;

    /// @notice y0 = CURVE_SUPPLY^2 / (CURVE_SUPPLY - LP_SUPPLY), rounded down.
    // forge-lint: disable-next-line(screaming-snake-case-const)
    uint256 public constant initialVirtualTokenReserve = CURVE_SUPPLY * CURVE_SUPPLY / (CURVE_SUPPLY - LP_SUPPLY);

    /// @notice Virtual token reserve once the whole CURVE_SUPPLY has been sold (y0 - CURVE_SUPPLY).
    uint256 public constant FINAL_VIRTUAL_TOKEN_RESERVE = initialVirtualTokenReserve - CURVE_SUPPLY;

    /// @notice Receiver of the PancakeSwap LP tokens minted at graduation (burned).
    address public constant LP_RECIPIENT = 0x000000000000000000000000000000000000dEaD;

    uint16 public constant MAX_FEE_BPS = 500;
    /// @notice Bounds on V0. Below 1 gwei, rounding would dominate prices. At or below 1e25 (10M BNB), the +1 wei
    /// from rounding the completing buy up is enough to keep the PancakeSwap listing price at or above the final
    /// curve price exactly, even though y0 is rounded down (3 * yEnd - 4 * LP_SUPPLY == -2).
    uint256 public constant MIN_INITIAL_VIRTUAL_BNB = 1e9;
    uint256 public constant MAX_INITIAL_VIRTUAL_BNB = 1e25;
    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_SYMBOL_BYTES = 16;
    uint256 public constant MAX_METADATA_BYTES = 1024;
    uint256 public constant MAX_PAGE_SIZE = 100;

    uint256 private constant _BPS = 10_000;

    /// @notice `renounceOwnership()` while paused would freeze creates, buys and graduations forever.
    error RenounceWhilePaused();

    // ------------------------------------------------------------------------------------------------ config

    // Getter names are fixed by IDprkLaunchpad.
    // forge-lint: disable-start(screaming-snake-case-immutable)
    /// @inheritdoc IDprkLaunchpad
    address public immutable pass;
    /// @inheritdoc IDprkLaunchpad
    address public immutable pancakeFactory;
    /// @inheritdoc IDprkLaunchpad
    address public immutable wbnb;
    /// @inheritdoc IDprkLaunchpad
    uint16 public immutable feeBps;
    /// @inheritdoc IDprkLaunchpad
    uint256 public immutable initialVirtualBnbReserve;
    /// @inheritdoc IDprkLaunchpad
    uint256 public immutable graduationBnb;

    // forge-lint: disable-end(screaming-snake-case-immutable)

    // ------------------------------------------------------------------------------------------------ state

    /// @dev Per-token curve. Virtual reserves are derived (see contract docs).
    struct Curve {
        address creator;
        uint64 createdAt;
        bool graduated;
        uint128 realBnbReserve;
        uint128 realTokenReserve;
        address pair;
    }

    /// @inheritdoc IDprkLaunchpad
    address public feeRecipient;
    /// @inheritdoc IDprkLaunchpad
    bool public paused;
    /// @inheritdoc IDprkLaunchpad
    uint256 public accruedFees;

    mapping(address token => Curve) private _curves;
    address[] private _tokens;

    /// @dev Result of the buy math, shared by `buy`, `createToken`, and the quote views.
    struct BuyQuote {
        uint256 tokensOut;
        uint256 fee;
        uint256 acceptedBnbIn;
        uint256 refund;
        uint256 netBnbIn;
        bool completes;
    }

    // ------------------------------------------------------------------------------------------------ setup

    constructor(
        address pass_,
        address pancakeFactory_,
        address wbnb_,
        address feeRecipient_,
        address owner_,
        uint256 initialVirtualBnbReserve_,
        uint16 feeBps_
    ) Ownable(owner_) {
        if (
            pass_.code.length == 0 || pancakeFactory_.code.length == 0 || wbnb_.code.length == 0
                || feeRecipient_ == address(0) || feeBps_ > MAX_FEE_BPS
                || initialVirtualBnbReserve_ < MIN_INITIAL_VIRTUAL_BNB
                || initialVirtualBnbReserve_ > MAX_INITIAL_VIRTUAL_BNB
        ) revert InvalidConfiguration();

        pass = pass_;
        pancakeFactory = pancakeFactory_;
        wbnb = wbnb_;
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
        initialVirtualBnbReserve = initialVirtualBnbReserve_;
        // Real BNB when the curve sells out along the k = k0 path: ceil(V0 * y0 / yEnd) - V0, which is 3 * V0 + 1
        // wei. Rounding only ever grows k, so a real curve sends at least this much to the pair, usually a few wei
        // more.
        graduationBnb = Math.mulDiv(
            initialVirtualBnbReserve_, initialVirtualTokenReserve, FINAL_VIRTUAL_TOKEN_RESERVE, Math.Rounding.Ceil
        ) - initialVirtualBnbReserve_;

        emit FeeRecipientUpdated(address(0), feeRecipient_);
    }

    // ------------------------------------------------------------------------------------------------ owner

    /// @notice Owner-only. Where `claimFees()` sends protocol fees. That includes fees that have already accrued
    /// but not been claimed yet, so this is admin trust over the whole unclaimed fee bucket. It never touches curve
    /// reserves.
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert InvalidConfiguration();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    /// @notice Owner-only. Pausing blocks `createToken` and `buy`. Graduation only happens inside a completing buy,
    /// so no curve can graduate while paused. Selling and fee claims keep working, so holders can always exit.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Owner-only, and only while unpaused. Renouncing while paused would make the pause permanent: no
    /// creates, buys or graduations ever again. Renouncing while unpaused leaves a launchpad that nobody can pause.
    function renounceOwnership() public override onlyOwner {
        if (paused) revert RenounceWhilePaused();
        super.renounceOwnership();
    }

    // ------------------------------------------------------------------------------------------------ actions

    /// @inheritdoc IDprkLaunchpad
    function createToken(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        uint256 minTokensOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokensOut) {
        _checkCanBuy(deadline);
        uint256 nameLength = bytes(name).length;
        uint256 symbolLength = bytes(symbol).length;
        if (
            nameLength == 0 || nameLength > MAX_NAME_BYTES || symbolLength == 0 || symbolLength > MAX_SYMBOL_BYTES
                || bytes(metadata).length > MAX_METADATA_BYTES
        ) revert InvalidMetadata();
        if (msg.value == 0 && minTokensOut != 0) revert SlippageExceeded(minTokensOut, 0);

        token = address(new DprkToken(name, symbol, metadata, msg.sender, pass, TOTAL_SUPPLY));

        Curve storage curve = _curves[token];
        curve.creator = msg.sender;
        curve.createdAt = uint64(block.timestamp);
        // forge-lint: disable-next-line(unsafe-typecast)
        curve.realTokenReserve = uint128(CURVE_SUPPLY); // 8e26 < 2^128
        _tokens.push(token);

        emit TokenCreated(token, msg.sender, name, symbol, metadata);

        if (msg.value != 0) tokensOut = _buy(token, curve, minTokensOut);
    }

    /// @inheritdoc IDprkLaunchpad
    function buy(address token, uint256 minTokensOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        _checkCanBuy(deadline);
        if (msg.value == 0) revert ZeroAmount();
        Curve storage curve = _activeCurve(token);
        tokensOut = _buy(token, curve, minTokensOut);
    }

    /// @inheritdoc IDprkLaunchpad
    function sell(address token, uint256 tokensIn, uint256 minBnbOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 bnbOut)
    {
        _checkDeadline(deadline);
        if (tokensIn == 0) revert ZeroAmount();
        Curve storage curve = _activeCurve(token);

        uint256 realBnb = curve.realBnbReserve;
        uint256 realToken = curve.realTokenReserve;
        (uint256 grossOut, uint256 fee) = _quoteSell(realBnb, realToken, tokensIn);
        bnbOut = grossOut - fee;
        if (bnbOut == 0) revert DustAmount();
        if (bnbOut < minBnbOut) revert SlippageExceeded(minBnbOut, bnbOut);

        realBnb -= grossOut;
        realToken += tokensIn;
        // forge-lint: disable-next-line(unsafe-typecast)
        curve.realBnbReserve = uint128(realBnb); // only decreased from a uint128
        curve.realTokenReserve = SafeCast.toUint128(realToken);
        accruedFees += fee;

        // Our own token: no hooks, returns true or reverts. `to == launchpad` passes the pre-graduation rule.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IDprkToken(token).transferFrom(msg.sender, address(this), tokensIn);
        _sendBnb(msg.sender, bnbOut);

        emit Trade(
            token,
            msg.sender,
            false,
            bnbOut,
            tokensIn,
            fee,
            realBnb + initialVirtualBnbReserve,
            realToken + FINAL_VIRTUAL_TOKEN_RESERVE,
            realBnb
        );
    }

    /// @inheritdoc IDprkLaunchpad
    function claimFees() external nonReentrant returns (uint256 amount) {
        amount = accruedFees;
        if (amount == 0) revert NoFeesAccrued();
        accruedFees = 0;
        address recipient = feeRecipient;
        _sendBnb(recipient, amount);
        emit FeesClaimed(recipient, amount);
    }

    // ------------------------------------------------------------------------------------------------ views

    /// @inheritdoc IDprkLaunchpad
    function quoteBuy(address token, uint256 bnbIn)
        external
        view
        returns (uint256 tokensOut, uint256 fee, uint256 acceptedBnbIn, uint256 refund)
    {
        Curve storage curve = _activeCurve(token);
        BuyQuote memory q = _quoteBuy(curve.realBnbReserve, curve.realTokenReserve, bnbIn);
        return (q.tokensOut, q.fee, q.acceptedBnbIn, q.refund);
    }

    /// @inheritdoc IDprkLaunchpad
    function quoteCreateBuy(uint256 bnbIn)
        external
        view
        returns (uint256 tokensOut, uint256 fee, uint256 acceptedBnbIn, uint256 refund)
    {
        BuyQuote memory q = _quoteBuy(0, CURVE_SUPPLY, bnbIn);
        return (q.tokensOut, q.fee, q.acceptedBnbIn, q.refund);
    }

    /// @inheritdoc IDprkLaunchpad
    function quoteSell(address token, uint256 tokensIn) external view returns (uint256 bnbOut, uint256 fee) {
        Curve storage curve = _activeCurve(token);
        uint256 grossOut;
        (grossOut, fee) = _quoteSell(curve.realBnbReserve, curve.realTokenReserve, tokensIn);
        bnbOut = grossOut - fee;
    }

    /// @inheritdoc IDprkLaunchpad
    function canTrade(address account) external view returns (bool) {
        return IDprkPass(pass).isCertified(account);
    }

    /// @inheritdoc IDprkLaunchpad
    function isLaunchToken(address token) external view returns (bool) {
        return _curves[token].creator != address(0);
    }

    /// @inheritdoc IDprkLaunchpad
    function getTokenState(address token) external view returns (TokenState memory) {
        return _tokenState(_knownCurve(token));
    }

    /// @inheritdoc IDprkLaunchpad
    function getTokenInfo(address token) external view returns (TokenInfo memory) {
        return _tokenInfo(token, _knownCurve(token));
    }

    /// @inheritdoc IDprkLaunchpad
    function getTokenInfos(uint256 offset, uint256 limit) external view returns (TokenInfo[] memory infos) {
        uint256 count = _tokens.length;
        if (offset >= count) return infos;
        uint256 n = Math.min(Math.min(limit, MAX_PAGE_SIZE), count - offset);
        infos = new TokenInfo[](n);
        for (uint256 i; i < n; ++i) {
            address token = _tokens[count - 1 - offset - i];
            infos[i] = _tokenInfo(token, _curves[token]);
        }
    }

    /// @inheritdoc IDprkLaunchpad
    function tokenCount() external view returns (uint256) {
        return _tokens.length;
    }

    /// @inheritdoc IDprkLaunchpad
    function tokenAt(uint256 index) external view returns (address) {
        return _tokens[index];
    }

    /// @inheritdoc IDprkLaunchpad
    function progressBps(address token) external view returns (uint256) {
        Curve storage curve = _knownCurve(token);
        return (CURVE_SUPPLY - curve.realTokenReserve) * _BPS / CURVE_SUPPLY;
    }

    // ------------------------------------------------------------------------------------------------ internals

    function _checkDeadline(uint256 deadline) private view {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
    }

    function _checkCanBuy(uint256 deadline) private view {
        if (paused) revert LaunchpadPaused();
        if (!IDprkPass(pass).isCertified(msg.sender)) revert NotCertified(msg.sender);
        _checkDeadline(deadline);
    }

    function _knownCurve(address token) private view returns (Curve storage curve) {
        curve = _curves[token];
        if (curve.creator == address(0)) revert UnknownToken(token);
    }

    function _activeCurve(address token) private view returns (Curve storage curve) {
        curve = _knownCurve(token);
        if (curve.graduated) revert AlreadyGraduated(token);
    }

    /// @dev Spends msg.value on `curve`, sends the tokens to msg.sender, graduates if the curve sold out, then
    /// refunds any excess. Effects happen before every external call, and the caller holds the reentrancy lock.
    function _buy(address token, Curve storage curve, uint256 minTokensOut) private returns (uint256 tokensOut) {
        uint256 realBnb = curve.realBnbReserve;
        uint256 realToken = curve.realTokenReserve;
        BuyQuote memory q = _quoteBuy(realBnb, realToken, msg.value);
        tokensOut = q.tokensOut;
        if (tokensOut == 0) revert DustAmount();
        if (tokensOut < minTokensOut) revert SlippageExceeded(minTokensOut, tokensOut);

        realBnb += q.netBnbIn;
        realToken -= tokensOut;
        curve.realBnbReserve = SafeCast.toUint128(realBnb);
        // forge-lint: disable-next-line(unsafe-typecast)
        curve.realTokenReserve = uint128(realToken); // only decreased from a uint128
        accruedFees += q.fee;

        // Our own token: returns true or reverts. `from == launchpad` passes the pre-graduation rule.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IDprkToken(token).transfer(msg.sender, tokensOut);

        emit Trade(
            token,
            msg.sender,
            true,
            q.acceptedBnbIn,
            tokensOut,
            q.fee,
            realBnb + initialVirtualBnbReserve,
            realToken + FINAL_VIRTUAL_TOKEN_RESERVE,
            realBnb
        );

        if (q.completes) _graduate(token, curve, realBnb);
        if (q.refund != 0) _sendBnb(msg.sender, q.refund);
    }

    /// @dev Seeds the PancakeSwap V2 pair with all of this curve's real BNB (as WBNB) plus LP_SUPPLY tokens and
    /// burns the minted LP to 0x...dEaD. A direct `mint` credits `balance - reserve` on both sides. Donated or
    /// synced WBNB therefore can't make it revert, and it only raises the price. The token side can't be pre-seeded
    /// (transfer rule), so totalSupply is 0 here and this is always the pair's first mint. Later protocol-fee LP
    /// (PancakeSwap `feeTo`) is minted by the pair, not by us, and isn't burned.
    function _graduate(address token, Curve storage curve, uint256 bnbLiquidity) private {
        curve.graduated = true;

        IPancakeV2Factory factory = IPancakeV2Factory(pancakeFactory);
        address pair = factory.getPair(token, wbnb);
        if (pair == address(0)) pair = factory.createPair(token, wbnb);
        curve.pair = pair;

        IDprkToken(token).markGraduated();

        IWBNB(wbnb).deposit{value: bnbLiquidity}();
        if (!IWBNB(wbnb).transfer(pair, bnbLiquidity)) revert BnbTransferFailed();
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IDprkToken(token).transfer(pair, LP_SUPPLY); // our own token: returns true or reverts
        uint256 liquidity = IPancakeV2Pair(pair).mint(LP_RECIPIENT);

        emit Graduated(token, pair, bnbLiquidity, LP_SUPPLY, liquidity);
    }

    /// @dev Buy math on a curve with the given real reserves. Never reverts. The callers handle zero/dust.
    function _quoteBuy(uint256 realBnb, uint256 realToken, uint256 bnbIn) private view returns (BuyQuote memory q) {
        uint256 x = realBnb + initialVirtualBnbReserve;
        uint256 y = realToken + FINAL_VIRTUAL_TOKEN_RESERVE;

        // Smallest net input that buys the whole remainder: x + net >= ceil(x * y / yEnd).
        uint256 netRequired = Math.mulDiv(x, y, FINAL_VIRTUAL_TOKEN_RESERVE, Math.Rounding.Ceil) - x;
        // Smallest gross input whose net reaches netRequired. Since net(g) = floor(g * (BPS - fee) / BPS),
        // net(g) >= netRequired  <=>  g >= ceil(netRequired * BPS / (BPS - fee)).
        uint256 grossRequired = Math.mulDiv(netRequired, _BPS, _BPS - feeBps, Math.Rounding.Ceil);

        if (bnbIn >= grossRequired) {
            q.completes = true;
            q.tokensOut = realToken;
            q.acceptedBnbIn = grossRequired;
            q.netBnbIn = netRequired;
            q.fee = grossRequired - netRequired;
            q.refund = bnbIn - grossRequired;
        } else {
            // bnbIn < grossRequired here, so the products below are small and net < netRequired, which means
            // tokensOut < realToken.
            q.acceptedBnbIn = bnbIn;
            q.netBnbIn = bnbIn * (_BPS - feeBps) / _BPS;
            q.fee = bnbIn - q.netBnbIn;
            q.tokensOut = Math.mulDiv(y, q.netBnbIn, x + q.netBnbIn);
        }
    }

    /// @dev Sell math. Returns gross BNB out of the curve and the fee taken from it.
    function _quoteSell(uint256 realBnb, uint256 realToken, uint256 tokensIn)
        private
        view
        returns (uint256 grossOut, uint256 fee)
    {
        uint256 x = realBnb + initialVirtualBnbReserve;
        uint256 y = realToken + FINAL_VIRTUAL_TOKEN_RESERVE;
        grossOut = Math.mulDiv(x, tokensIn, y + tokensIn);
        // Unreachable for any amount a holder can own (k >= k0 keeps x >= V0 after selling every circulating
        // token). Kept as a backstop so the curve can never pay out another curve's BNB or the fee bucket.
        if (grossOut > realBnb) revert InsufficientRealBnbReserve(grossOut, realBnb);
        fee = Math.mulDiv(grossOut, feeBps, _BPS, Math.Rounding.Ceil);
    }

    function _tokenState(Curve storage curve) private view returns (TokenState memory state) {
        uint256 realBnb = curve.realBnbReserve;
        uint256 realToken = curve.realTokenReserve;
        state = TokenState({
            creator: curve.creator,
            createdAt: curve.createdAt,
            graduated: curve.graduated,
            pair: curve.pair,
            virtualBnbReserve: realBnb + initialVirtualBnbReserve,
            virtualTokenReserve: realToken + FINAL_VIRTUAL_TOKEN_RESERVE,
            realBnbReserve: realBnb,
            realTokenReserve: realToken
        });
    }

    function _tokenInfo(address token, Curve storage curve) private view returns (TokenInfo memory info) {
        info.token = token;
        info.name = IERC20Metadata(token).name();
        info.symbol = IERC20Metadata(token).symbol();
        info.metadata = IDprkToken(token).metadata();
        info.state = _tokenState(curve);
    }

    /// @dev Sends BNB without copying return data. Callers have already updated state and hold the lock.
    function _sendBnb(address to, uint256 amount) private {
        bool ok;
        assembly ("memory-safe") {
            ok := call(gas(), to, amount, 0, 0, 0, 0)
        }
        if (!ok) revert BnbTransferFailed();
    }
}
