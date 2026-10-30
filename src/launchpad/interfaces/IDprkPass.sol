// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

/// @notice ERC-5192 minimal soulbound interface (interfaceId 0xb45a3c0e).
interface IERC5192 {
    event Locked(uint256 tokenId);
    event Unlocked(uint256 tokenId);

    function locked(uint256 tokenId) external view returns (bool);
}

/// @title DPRK.FUN Not-Lazarus Pass
/// @notice Soulbound ERC-721. It can only be claimed by an address that has called both `pig()` and `fuck()`
/// on the KimJongUn registry ("김정은 개새끼" on-chain). Holding a pass is the gate for the DPRK.FUN launchpad.
interface IDprkPass is IERC721Metadata, IERC5192 {
    event PassClaimed(address indexed holder, uint256 indexed tokenId);

    error NotPiggedAndFucked(address account);
    error AlreadyCertified(address account);
    error Soulbound();

    /// @notice KimJongUn registry consulted by `claim()`.
    function kimJongUn() external view returns (address);

    /// @notice Mints the caller's pass. Reverts with `NotPiggedAndFucked` unless
    /// `kimJongUn().hasPiggedAndFuckedKimJongUn(msg.sender)`, and with `AlreadyCertified` on a second claim.
    /// Token ids start at 1 and increase by one per claim.
    function claim() external returns (uint256 tokenId);

    /// @notice True when `account` holds a pass.
    function isCertified(address account) external view returns (bool);

    /// @notice The pass token id held by `account`, or 0 if none.
    function passOf(address account) external view returns (uint256 tokenId);

    /// @notice Number of passes ever claimed (equals the highest token id).
    function totalClaimed() external view returns (uint256);
}
