// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {KimJongUn} from "../src/KimJongUn.sol";
import {KimJongUnEligibilityHook} from "../src/hooks/KimJongUnEligibilityHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract KimJongUnTest is Test {
    KimJongUn internal kimJongUn;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal poolManager = address(0xBEEF);
    address internal trustedForwarder = address(0xF00D);
    address internal mallory = address(0xBAD);

    function setUp() public {
        kimJongUn = new KimJongUn();
    }

    function test_pigMarksCallerAsNotNorthKoreanHackerActor() public {
        vm.prank(alice);
        kimJongUn.pig();

        assertTrue(kimJongUn.isRegardedAsNotNorthKoreanHackerActor(alice));
        assertTrue(kimJongUn.hasPiggedKimJongUn(alice));
        assertFalse(kimJongUn.hasFuckedKimJongUn(alice));
        assertTrue(kimJongUn.hasPiggedOrFuckedKimJongUn(alice));
        assertFalse(kimJongUn.hasPiggedAndFuckedKimJongUn(alice));
        assertEq(kimJongUn.pigCalls(alice), 1);
        assertEq(kimJongUn.fuckCalls(alice), 0);
        assertEq(kimJongUn.totalPigCalls(), 1);
        assertEq(kimJongUn.totalFuckCalls(), 0);
        assertEq(kimJongUn.totalVerifiedAddresses(), 1);
    }

    function test_fuckMarksCallerAsNotNorthKoreanHackerActor() public {
        vm.prank(alice);
        kimJongUn.fuck();

        assertTrue(kimJongUn.isRegardedAsNotNorthKoreanHackerActor(alice));
        assertFalse(kimJongUn.hasPiggedKimJongUn(alice));
        assertTrue(kimJongUn.hasFuckedKimJongUn(alice));
        assertTrue(kimJongUn.hasPiggedOrFuckedKimJongUn(alice));
        assertFalse(kimJongUn.hasPiggedAndFuckedKimJongUn(alice));
        assertEq(kimJongUn.pigCalls(alice), 0);
        assertEq(kimJongUn.fuckCalls(alice), 1);
        assertEq(kimJongUn.totalPigCalls(), 0);
        assertEq(kimJongUn.totalFuckCalls(), 1);
        assertEq(kimJongUn.totalVerifiedAddresses(), 1);
    }

    function test_verifiedAddressCountOnlyIncrementsOncePerAddress() public {
        vm.startPrank(alice);
        kimJongUn.pig();
        kimJongUn.fuck();
        kimJongUn.fuck();
        vm.stopPrank();

        assertTrue(kimJongUn.isRegardedAsNotNorthKoreanHackerActor(alice));
        assertTrue(kimJongUn.hasPiggedKimJongUn(alice));
        assertTrue(kimJongUn.hasFuckedKimJongUn(alice));
        assertTrue(kimJongUn.hasPiggedOrFuckedKimJongUn(alice));
        assertTrue(kimJongUn.hasPiggedAndFuckedKimJongUn(alice));
        assertEq(kimJongUn.pigCalls(alice), 1);
        assertEq(kimJongUn.fuckCalls(alice), 2);
        assertEq(kimJongUn.totalPigCalls(), 1);
        assertEq(kimJongUn.totalFuckCalls(), 2);
        assertEq(kimJongUn.totalVerifiedAddresses(), 1);
    }

    function test_multipleAddressesAreTrackedIndependently() public {
        vm.prank(alice);
        kimJongUn.pig();

        vm.prank(bob);
        kimJongUn.fuck();

        assertTrue(kimJongUn.isRegardedAsNotNorthKoreanHackerActor(alice));
        assertTrue(kimJongUn.isRegardedAsNotNorthKoreanHackerActor(bob));
        assertEq(kimJongUn.pigCalls(alice), 1);
        assertEq(kimJongUn.fuckCalls(alice), 0);
        assertEq(kimJongUn.pigCalls(bob), 0);
        assertEq(kimJongUn.fuckCalls(bob), 1);
        assertEq(kimJongUn.totalVerifiedAddresses(), 2);
    }

    function test_hasPiggedAndFuckedCheckerRequiresBothActions() public {
        vm.prank(alice);
        kimJongUn.pig();

        assertFalse(kimJongUn.hasPiggedAndFuckedKimJongUn(alice));

        vm.prank(alice);
        kimJongUn.fuck();

        assertTrue(kimJongUn.hasPiggedAndFuckedKimJongUn(alice));
    }

    function test_hookAllowsQualifiedDirectPoolManagerCaller() public {
        vm.startPrank(alice);
        kimJongUn.pig();
        kimJongUn.fuck();
        vm.stopPrank();

        KimJongUnEligibilityHook hook = _deployHook();
        PoolKey memory key = _poolKey(address(hook));
        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1, salt: bytes32(0)});

        vm.startPrank(poolManager);
        (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride) =
            hook.beforeSwap(alice, key, swapParams, bytes(""));
        bytes4 addSelector = hook.beforeAddLiquidity(alice, key, liquidityParams, bytes(""));
        bytes4 removeSelector = hook.beforeRemoveLiquidity(alice, key, liquidityParams, bytes(""));
        vm.stopPrank();

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
        assertEq(feeOverride, 0);
        assertEq(addSelector, IHooks.beforeAddLiquidity.selector);
        assertEq(removeSelector, IHooks.beforeRemoveLiquidity.selector);
        assertTrue(hook.isEligible(alice));
        assertFalse(hook.isEligible(bob));
    }

    function test_hookAllowsTrustedForwarderToPassVerifiedEndUser() public {
        vm.startPrank(alice);
        kimJongUn.pig();
        kimJongUn.fuck();
        vm.stopPrank();

        KimJongUnEligibilityHook hook = _deployHook();
        PoolKey memory key = _poolKey(address(hook));
        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1, salt: bytes32(0)});
        bytes memory forwardedAlice = abi.encode(alice);

        vm.startPrank(poolManager);
        (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride) =
            hook.beforeSwap(trustedForwarder, key, swapParams, forwardedAlice);
        bytes4 addSelector = hook.beforeAddLiquidity(trustedForwarder, key, liquidityParams, forwardedAlice);
        bytes4 removeSelector = hook.beforeRemoveLiquidity(trustedForwarder, key, liquidityParams, forwardedAlice);
        vm.stopPrank();

        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
        assertEq(feeOverride, 0);
        assertEq(addSelector, IHooks.beforeAddLiquidity.selector);
        assertEq(removeSelector, IHooks.beforeRemoveLiquidity.selector);
    }

    function test_hookRejectsUnqualifiedSwapsAndLiquidityProvision() public {
        KimJongUnEligibilityHook hook = _deployHook();
        PoolKey memory key = _poolKey(address(hook));
        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        ModifyLiquidityParams memory liquidityParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1, salt: bytes32(0)});

        vm.startPrank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(KimJongUnEligibilityHook.NotPiggedAndFuckedKimJongUn.selector, bob));
        hook.beforeSwap(bob, key, swapParams, bytes(""));

        vm.expectRevert(abi.encodeWithSelector(KimJongUnEligibilityHook.NotPiggedAndFuckedKimJongUn.selector, bob));
        hook.beforeAddLiquidity(bob, key, liquidityParams, bytes(""));
        vm.stopPrank();
    }

    function test_hookRejectsSpoofedUserFromUntrustedForwarder() public {
        vm.startPrank(alice);
        kimJongUn.pig();
        kimJongUn.fuck();
        vm.stopPrank();

        KimJongUnEligibilityHook hook = _deployHook();
        PoolKey memory key = _poolKey(address(hook));
        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        bytes memory forwardedAlice = abi.encode(alice);

        vm.startPrank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(KimJongUnEligibilityHook.UntrustedForwarder.selector, mallory));
        hook.beforeSwap(mallory, key, swapParams, forwardedAlice);
        vm.stopPrank();
    }

    function test_hookRejectsMalformedHookData() public {
        KimJongUnEligibilityHook hook = _deployHook();
        PoolKey memory key = _poolKey(address(hook));
        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.startPrank(poolManager);
        vm.expectRevert(KimJongUnEligibilityHook.InvalidHookData.selector);
        hook.beforeSwap(alice, key, swapParams, hex"1234");
        vm.stopPrank();
    }

    function _deployHook() internal returns (KimJongUnEligibilityHook hook) {
        uint160 flags = Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG;
        address hookAddress = address(flags);

        deployCodeTo(
            "KimJongUnEligibilityHook.sol:KimJongUnEligibilityHook",
            abi.encode(IPoolManager(poolManager), kimJongUn, trustedForwarder),
            hookAddress
        );

        hook = KimJongUnEligibilityHook(hookAddress);
    }

    function _poolKey(address hookAddress) internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
    }
}
