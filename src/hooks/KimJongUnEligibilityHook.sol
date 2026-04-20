// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {KimJongUn} from "../KimJongUn.sol";
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Example Uniswap v4 hook that only allows swaps and liquidity operations
/// for addresses that have both pigged and fucked Kim Jong Un.
/// @dev Hook contracts must be deployed to an address whose low bits match the enabled hook permissions.
contract KimJongUnEligibilityHook is BaseHook {
    KimJongUn public immutable VERIFIER;
    address public immutable TRUSTED_FORWARDER;

    error NotPiggedAndFuckedKimJongUn(address caller);
    error InvalidHookData();
    error UntrustedForwarder(address caller);

    constructor(IPoolManager poolManager_, KimJongUn verifier_, address trustedForwarder_) BaseHook(poolManager_) {
        VERIFIER = verifier_;
        TRUSTED_FORWARDER = trustedForwarder_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function isEligible(address account) public view returns (bool) {
        return VERIFIER.hasPiggedAndFuckedKimJongUn(account);
    }

    function _beforeSwap(address sender, PoolKey calldata, SwapParams calldata, bytes calldata hookData)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _requireEligible(_resolveAccount(sender, hookData));
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) internal view override returns (bytes4) {
        _requireEligible(_resolveAccount(sender, hookData));
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) internal view override returns (bytes4) {
        _requireEligible(_resolveAccount(sender, hookData));
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _requireEligible(address caller) internal view {
        if (!isEligible(caller)) revert NotPiggedAndFuckedKimJongUn(caller);
    }

    function _resolveAccount(address sender, bytes calldata hookData) internal view returns (address account) {
        if (hookData.length == 0) {
            return sender;
        }

        if (hookData.length != 32) revert InvalidHookData();

        account = abi.decode(hookData, (address));

        if (sender != account && sender != TRUSTED_FORWARDER) {
            revert UntrustedForwarder(sender);
        }
    }
}
