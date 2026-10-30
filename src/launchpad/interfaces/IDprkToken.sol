// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title DPRK.FUN launch token
/// @notice Fixed-supply ERC-20 deployed by the launchpad. Before graduation a transfer is allowed only when it
/// mints, comes from the launchpad, goes to the launchpad, or goes to a certified (pass-holding) address. That
/// keeps uncertified wallets (and the PancakeSwap pair) from holding curve tokens. After graduation it is a
/// plain ERC-20 with no owner, tax, mint, or blacklist.
interface IDprkToken is IERC20Metadata {
    error TransferLocked(address from, address to);
    error OnlyLaunchpad();

    /// @notice Launchpad that received the entire supply and runs the bonding curve.
    function launchpad() external view returns (address);

    /// @notice Pass contract used by the pre-graduation transfer rule.
    function pass() external view returns (address);

    /// @notice Address that created the token through the launchpad.
    function creator() external view returns (address);

    /// @notice Creator-supplied JSON metadata (see docs/BSC_LAUNCHPAD.md). Untrusted input.
    function metadata() external view returns (string memory);

    /// @notice False while the token trades on the bonding curve.
    function graduated() external view returns (bool);

    /// @notice Launchpad-only. Permanently lifts the pre-graduation transfer rule.
    function markGraduated() external;
}
