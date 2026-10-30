// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DPRK.FUN launchpad
/// @notice Single-contract bonding-curve launchpad for BNB Chain. Only certified addresses (DPRK.FUN pass holders)
/// can create tokens or buy from a curve. Selling back to the curve is always open, and pausing never blocks it.
/// When a curve sells its whole CURVE_SUPPLY it graduates in the same transaction. Graduation only ever happens
/// inside that completing buy, so it waits while buys are paused. Graduation sends all real BNB plus LP_SUPPLY tokens
/// to the PancakeSwap V2 pair and burns the minted LP tokens to 0x...dEaD. (PancakeSwap's `feeTo` can still mint
/// protocol-fee LP later, so not 100% of the pool is locked forever.)
/// @dev Anyone can deploy look-alike DprkToken contracts. Integrators must check `isLaunchToken(token)`.
interface IDprkLaunchpad {
    struct TokenState {
        address creator;
        uint64 createdAt;
        bool graduated;
        /// @dev PancakeSwap V2 pair. Zero until graduation.
        address pair;
        uint256 virtualBnbReserve;
        uint256 virtualTokenReserve;
        /// @dev BNB held for this curve, excluding protocol fees. After graduation it is frozen at the amount that went
        /// into the pair, and the launchpad no longer holds it.
        uint256 realBnbReserve;
        /// @dev Tokens still purchasable from the curve, excluding the LP allocation.
        uint256 realTokenReserve;
    }

    struct TokenInfo {
        address token;
        string name;
        string symbol;
        string metadata;
        TokenState state;
    }

    event TokenCreated(address indexed token, address indexed creator, string name, string symbol, string metadata);

    /// @param bnbAmount buy: gross BNB accepted including fee and excluding refund; sell: net BNB paid to trader.
    /// @param virtualBnbReserve post-trade virtual BNB reserve.
    /// @param virtualTokenReserve post-trade virtual token reserve.
    /// @param realBnbReserve post-trade real BNB reserve.
    event Trade(
        address indexed token,
        address indexed trader,
        bool indexed isBuy,
        uint256 bnbAmount,
        uint256 tokenAmount,
        uint256 fee,
        uint256 virtualBnbReserve,
        uint256 virtualTokenReserve,
        uint256 realBnbReserve
    );

    event Graduated(
        address indexed token, address indexed pair, uint256 bnbLiquidity, uint256 tokenLiquidity, uint256 liquidity
    );
    event FeesClaimed(address indexed recipient, uint256 amount);
    event FeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event PausedSet(bool paused);

    error NotCertified(address account);
    error LaunchpadPaused();
    error UnknownToken(address token);
    error AlreadyGraduated(address token);
    error InvalidMetadata();
    error ZeroAmount();
    error DustAmount();
    error SlippageExceeded(uint256 minimum, uint256 actual);
    error DeadlineExpired(uint256 deadline, uint256 timestamp);
    error InsufficientRealBnbReserve(uint256 requested, uint256 available);
    error BnbTransferFailed();
    error InvalidConfiguration();
    error NoFeesAccrued();

    // ---------------------------------------------------------------- configuration

    function pass() external view returns (address);
    function pancakeFactory() external view returns (address);
    function wbnb() external view returns (address);
    function feeRecipient() external view returns (address);
    function feeBps() external view returns (uint16);
    function paused() external view returns (bool);
    function accruedFees() external view returns (uint256);

    function TOTAL_SUPPLY() external view returns (uint256);
    function CURVE_SUPPLY() external view returns (uint256);
    function LP_SUPPLY() external view returns (uint256);
    function initialVirtualBnbReserve() external view returns (uint256);
    function initialVirtualTokenReserve() external view returns (uint256);

    /// @notice Real BNB (fees excluded) a curve sends to the pair when it sells out: about 3 * V0. Exactly, this is
    /// the k = k0 value ceil(V0 * y0 / yEnd) - V0 = 3 * V0 + 1 wei. Rounding during trading adds a few more wei.
    function graduationBnb() external view returns (uint256);

    // ---------------------------------------------------------------- actions

    /// @notice Deploys a new token. Any msg.value is an initial buy for the creator, and `minTokensOut` applies to
    /// that buy. With msg.value == 0, `tokensOut` is 0 and `minTokensOut` must be 0.
    function createToken(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        uint256 minTokensOut,
        uint256 deadline
    ) external payable returns (address token, uint256 tokensOut);

    /// @notice Buys from the curve with msg.value. The caller must be certified. Excess BNB past the graduation
    /// point is refunded, and a buy that sells out the curve also graduates it.
    function buy(address token, uint256 minTokensOut, uint256 deadline) external payable returns (uint256 tokensOut);

    /// @notice Sells `tokensIn` back to the curve. It needs a prior ERC-20 approval and is open to anyone.
    function sell(address token, uint256 tokensIn, uint256 minBnbOut, uint256 deadline)
        external
        returns (uint256 bnbOut);

    /// @notice Sends all accrued protocol fees to `feeRecipient()`. Callable by anyone.
    function claimFees() external returns (uint256 amount);

    // ---------------------------------------------------------------- views

    function quoteBuy(address token, uint256 bnbIn)
        external
        view
        returns (uint256 tokensOut, uint256 fee, uint256 acceptedBnbIn, uint256 refund);

    /// @notice Quote for the initial buy on a not-yet-created curve (what `createToken` will do with `bnbIn`).
    function quoteCreateBuy(uint256 bnbIn)
        external
        view
        returns (uint256 tokensOut, uint256 fee, uint256 acceptedBnbIn, uint256 refund);

    function quoteSell(address token, uint256 tokensIn) external view returns (uint256 bnbOut, uint256 fee);

    /// @notice True when `account` may create tokens and buy (holds a DPRK.FUN pass).
    function canTrade(address account) external view returns (bool);

    function isLaunchToken(address token) external view returns (bool);
    function getTokenState(address token) external view returns (TokenState memory);
    function getTokenInfo(address token) external view returns (TokenInfo memory);

    /// @notice Newest first. `offset` 0 is the most recent token, and `limit` is capped at 100.
    function getTokenInfos(uint256 offset, uint256 limit) external view returns (TokenInfo[] memory infos);

    function tokenCount() external view returns (uint256);

    /// @notice Creation order: index 0 is the first token ever created.
    function tokenAt(uint256 index) external view returns (address);

    /// @notice Share of CURVE_SUPPLY sold, in basis points, rounded down. 10_000 only once graduated.
    function progressBps(address token) external view returns (uint256);
}
