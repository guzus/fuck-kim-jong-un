// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Ported from the independent review's regression suite (ReviewAdversarialInvariant).

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {DprkToken} from "../../src/launchpad/DprkToken.sol";
import {IDprkLaunchpad} from "../../src/launchpad/interfaces/IDprkLaunchpad.sol";
import {IPancakeV2Pair} from "../../src/launchpad/interfaces/IPancakeV2.sol";
import {AdversarialPairHandler} from "./handlers/AdversarialPairHandler.sol";
import {LaunchpadTestBase} from "./utils/LaunchpadTestBase.sol";

/// @notice Stateful invariants against an adversarial pair handler. An uncertified griefer pre-creates pairs
/// (including for token addresses that don't exist yet), donates and syncs WBNB, skims, tries mint/burn/swap,
/// toggles PancakeSwap's feeTo, and forces BNB into the launchpad. foundry.toml sets fail_on_revert = true, so any
/// graduation that reverts fails the run.
contract DprkLaunchpadAdversarialInvariantTest is StdInvariant, LaunchpadTestBase {
    AdversarialPairHandler internal handler;

    function setUp() public override {
        super.setUp();
        address dave = makeAddr("dave");
        _certify(dave);
        address[] memory actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = dave;
        handler = new AdversarialPairHandler(launchpad, wbnb, factory, actors, mallory);
        factory.setFeeToSetter(address(handler));

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = AdversarialPairHandler.createToken.selector;
        selectors[1] = AdversarialPairHandler.createToken.selector;
        selectors[2] = AdversarialPairHandler.buy.selector;
        selectors[3] = AdversarialPairHandler.buy.selector;
        selectors[4] = AdversarialPairHandler.sell.selector;
        selectors[5] = AdversarialPairHandler.griefPredictedPair.selector;
        selectors[6] = AdversarialPairHandler.griefPair.selector;
        selectors[7] = AdversarialPairHandler.griefPair.selector;
        selectors[8] = AdversarialPairHandler.griefPair.selector;
        selectors[9] = AdversarialPairHandler.forceBnb.selector;
        selectors[10] = AdversarialPairHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_noPairGriefSucceededBeforeGraduation() public view {
        assertFalse(handler.pairGriefSucceeded());
    }

    function invariant_everyGraduationListedCorrectly() public view {
        assertFalse(handler.badGraduation());
    }

    /// Pre-graduation pairs never hold tokens or LP, and kLast stays 0.
    function invariant_preGraduationPairsAreEmpty() public view {
        for (uint256 i; i < handler.tokenCount(); ++i) {
            address token = handler.tokens(i);
            if (DprkToken(token).graduated()) continue;
            address pair = factory.getPair(token, address(wbnb));
            if (pair == address(0)) continue;
            assertEq(DprkToken(token).balanceOf(pair), 0);
            assertEq(IPancakeV2Pair(pair).totalSupply(), 0);
            assertEq(IPancakeV2Pair(pair).kLast(), 0);
        }
    }

    function invariant_solvencyWithForcedBnb() public view {
        uint256 sum;
        for (uint256 i; i < handler.tokenCount(); ++i) {
            IDprkLaunchpad.TokenState memory s = launchpad.getTokenState(handler.tokens(i));
            if (!s.graduated) sum += s.realBnbReserve;
        }
        assertEq(address(launchpad).balance, sum + launchpad.accruedFees() + handler.forcedBnb());
    }

    function afterInvariant() external view {
        console.log("graduations", handler.graduations(), "completing buys", handler.completingBuys());
        console.log("pre-graduation grief calls", handler.preGraduationGriefCalls());
        console.log("completing buys into pre-created pair", handler.gradsIntoPrecreatedPair());
        console.log(
            "  ...with synced donation", handler.gradsIntoSyncedDonation(), "with feeTo on", handler.gradsWithFeeOn()
        );
    }
}
