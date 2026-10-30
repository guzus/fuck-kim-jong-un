// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Local-chain stand-in for the PancakeSwap V2 factory, written from scratch. It is behaviour-compatible
/// for what the launchpad and its tests touch: `getPair` in both orders, `createPair` (sorted tokens, CREATE2,
/// PAIR_EXISTS), and the `feeTo` switch that turns on the pair's protocol-fee mint.
contract MockPancakeFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256);

    address public feeTo;
    address public feeToSetter;
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    constructor(address feeToSetter_) {
        feeToSetter = feeToSetter_;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "Pancake: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "Pancake: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "Pancake: PAIR_EXISTS");
        pair = address(new MockPancakePair{salt: keccak256(abi.encodePacked(token0, token1))}());
        MockPancakePair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address feeTo_) external {
        require(msg.sender == feeToSetter, "Pancake: FORBIDDEN");
        feeTo = feeTo_;
    }

    function setFeeToSetter(address feeToSetter_) external {
        require(msg.sender == feeToSetter, "Pancake: FORBIDDEN");
        feeToSetter = feeToSetter_;
    }
}

/// @notice Local-chain stand-in for a PancakeSwap V2 pair, written from scratch (no Uniswap/PancakeSwap code).
/// It mirrors the behaviour the launchpad relies on:
/// - `mint` credits `balance - reserve` on each side; the first mint gives `sqrt(a0 * a1) - 1000` and locks 1000
///   LP at address(0);
/// - the protocol fee (when the factory's `feeTo` is set) is minted on `mint`/`burn` from sqrt(k) growth, with
///   PancakeSwap's 8/25 share, and `kLast` is tracked;
/// - `swap` takes a 0.25% input fee and enforces the k check; `skim`, `sync`, and the uint112 reserve cap apply.
/// Flash swaps (non-empty `data`) and the TWAP accumulators are not implemented.
contract MockPancakePair {
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    string public constant name = "Pancake LPs";
    string public constant symbol = "Cake-LP";
    uint8 public constant decimals = 18;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    address public immutable factory;
    address public token0;
    address public token1;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint112 private _reserve0;
    uint112 private _reserve1;
    uint32 private _blockTimestampLast;
    uint256 public kLast;

    bool private _entered;

    modifier lock() {
        require(!_entered, "Pancake: LOCKED");
        _entered = true;
        _;
        _entered = false;
    }

    constructor() {
        factory = msg.sender;
    }

    function initialize(address token0_, address token1_) external {
        require(msg.sender == factory && token0 == address(0), "Pancake: FORBIDDEN");
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() public view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) {
        return (_reserve0, _reserve1, _blockTimestampLast);
    }

    // ------------------------------------------------------------------------------------------- LP token

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= value;
        _move(from, to, value);
        return true;
    }

    function _move(address from, address to, uint256 value) private {
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    function _mintLp(address to, uint256 value) private {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function _burnLp(address from, uint256 value) private {
        balanceOf[from] -= value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
    }

    // ------------------------------------------------------------------------------------------- AMM

    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 reserve0, uint112 reserve1,) = getReserves();
        uint256 balance0 = IERC20Balance(token0).balanceOf(address(this));
        uint256 balance1 = IERC20Balance(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - reserve0;
        uint256 amount1 = balance1 - reserve1;

        bool feeOn = _mintFee(reserve0, reserve1);
        uint256 supply = totalSupply; // after _mintFee, as in PancakeSwap
        if (supply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY; // reverts below the minimum
            _mintLp(address(0), MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min(amount0 * supply / reserve0, amount1 * supply / reserve1);
        }
        require(liquidity > 0, "Pancake: INSUFFICIENT_LIQUIDITY_MINTED");
        _mintLp(to, liquidity);

        _update(balance0, balance1);
        if (feeOn) kLast = uint256(_reserve0) * _reserve1;
        emit Mint(msg.sender, amount0, amount1);
    }

    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        (uint112 reserve0, uint112 reserve1,) = getReserves();
        uint256 balance0 = IERC20Balance(token0).balanceOf(address(this));
        uint256 balance1 = IERC20Balance(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(reserve0, reserve1);
        uint256 supply = totalSupply;
        amount0 = liquidity * balance0 / supply;
        amount1 = liquidity * balance1 / supply;
        require(amount0 > 0 && amount1 > 0, "Pancake: INSUFFICIENT_LIQUIDITY_BURNED");
        _burnLp(address(this), liquidity);
        _safeTransfer(token0, to, amount0);
        _safeTransfer(token1, to, amount1);

        _update(IERC20Balance(token0).balanceOf(address(this)), IERC20Balance(token1).balanceOf(address(this)));
        if (feeOn) kLast = uint256(_reserve0) * _reserve1;
        emit Burn(msg.sender, amount0, amount1, to);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external lock {
        require(data.length == 0, "MockPancakePair: no flash swaps");
        require(amount0Out > 0 || amount1Out > 0, "Pancake: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 reserve0, uint112 reserve1,) = getReserves();
        require(amount0Out < reserve0 && amount1Out < reserve1, "Pancake: INSUFFICIENT_LIQUIDITY");
        require(to != token0 && to != token1, "Pancake: INVALID_TO");

        if (amount0Out > 0) _safeTransfer(token0, to, amount0Out);
        if (amount1Out > 0) _safeTransfer(token1, to, amount1Out);
        uint256 balance0 = IERC20Balance(token0).balanceOf(address(this));
        uint256 balance1 = IERC20Balance(token1).balanceOf(address(this));

        uint256 amount0In = balance0 > reserve0 - amount0Out ? balance0 - (reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > reserve1 - amount1Out ? balance1 - (reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "Pancake: INSUFFICIENT_INPUT_AMOUNT");
        uint256 adjusted0 = balance0 * 10_000 - amount0In * 25;
        uint256 adjusted1 = balance1 * 10_000 - amount1In * 25;
        require(adjusted0 * adjusted1 >= uint256(reserve0) * reserve1 * 1e8, "Pancake: K");

        _update(balance0, balance1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    function skim(address to) external lock {
        _safeTransfer(token0, to, IERC20Balance(token0).balanceOf(address(this)) - _reserve0);
        _safeTransfer(token1, to, IERC20Balance(token1).balanceOf(address(this)) - _reserve1);
    }

    function sync() external lock {
        _update(IERC20Balance(token0).balanceOf(address(this)), IERC20Balance(token1).balanceOf(address(this)));
    }

    // ------------------------------------------------------------------------------------------- internals

    function _update(uint256 balance0, uint256 balance1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "Pancake: OVERFLOW");
        _reserve0 = uint112(balance0);
        _reserve1 = uint112(balance1);
        _blockTimestampLast = uint32(block.timestamp);
        emit Sync(_reserve0, _reserve1);
    }

    /// @dev Protocol fee: 8/25 of the sqrt(k) growth since `kLast`, minted as LP to `feeTo`.
    function _mintFee(uint112 reserve0, uint112 reserve1) private returns (bool feeOn) {
        address feeTo = MockPancakeFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 lastK = kLast;
        if (feeOn) {
            if (lastK != 0) {
                uint256 rootK = Math.sqrt(uint256(reserve0) * reserve1);
                uint256 rootKLast = Math.sqrt(lastK);
                if (rootK > rootKLast) {
                    uint256 liquidity = totalSupply * (rootK - rootKLast) * 8 / (rootK * 17 + rootKLast * 8);
                    if (liquidity > 0) _mintLp(feeTo, liquidity);
                }
            }
        } else if (lastK != 0) {
            kLast = 0;
        }
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "Pancake: TRANSFER_FAILED");
    }
}
