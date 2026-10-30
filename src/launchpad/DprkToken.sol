// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDprkToken} from "./interfaces/IDprkToken.sol";
import {IDprkPass} from "./interfaces/IDprkPass.sol";

/// @title DPRK.FUN launch token
/// @notice Fixed-supply ERC-20. The whole supply is minted once, to the launchpad that deploys it. There is no
/// owner, no mint after construction, no tax, and no blacklist.
/// @dev Pre-graduation transfer rule (see docs/BSC_LAUNCHPAD.md): a balance change is allowed iff it is the
/// constructor mint, OR it comes from the launchpad, OR it goes to the launchpad, OR the receiver holds a
/// DPRK.FUN pass. Three properties follow:
/// - The PancakeSwap pair can't hold tokens before graduation. It can't claim a pass and the launchpad only ever
///   sends tokens to the certified buyer, so nobody can pre-seed the pool and grief the graduation mint.
/// - Selling back to the curve never depends on certification or on the pass contract: `to == launchpad` is
///   checked before the pass is consulted.
/// - Passes are soulbound and can't be burned, so certification never goes away. A holder can always sell or move
///   tokens to another pass holder.
/// `markGraduated()` lifts the rule permanently. The launchpad calls it at the start of graduation.
contract DprkToken is ERC20, IDprkToken {
    // Getter names are fixed by IDprkToken.
    // forge-lint: disable-start(screaming-snake-case-immutable)
    /// @inheritdoc IDprkToken
    address public immutable launchpad;
    /// @inheritdoc IDprkToken
    address public immutable pass;
    /// @inheritdoc IDprkToken
    address public immutable creator;
    // forge-lint: disable-end(screaming-snake-case-immutable)
    /// @inheritdoc IDprkToken
    bool public graduated;

    string private _metadata;

    constructor(
        string memory name_,
        string memory symbol_,
        string memory metadata_,
        address creator_,
        address pass_,
        uint256 totalSupply_
    ) ERC20(name_, symbol_) {
        launchpad = msg.sender;
        pass = pass_;
        creator = creator_;
        _metadata = metadata_;
        _mint(msg.sender, totalSupply_);
    }

    /// @inheritdoc IDprkToken
    function metadata() external view returns (string memory) {
        return _metadata;
    }

    /// @inheritdoc IDprkToken
    function markGraduated() external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        graduated = true;
    }

    /// @dev Cheapest checks first: the launchpad's own transfers (buys, sells, graduation) never touch the
    /// `graduated` slot or the pass contract.
    function _update(address from, address to, uint256 value) internal override {
        if (
            from != launchpad && to != launchpad && from != address(0) && !graduated && !IDprkPass(pass).isCertified(to)
        ) revert TransferLocked(from, to);
        super._update(from, to, value);
    }
}
