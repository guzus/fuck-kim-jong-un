// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IDprkPass} from "./interfaces/IDprkPass.sol";

/// @notice The part of the KimJongUn registry (`src/KimJongUn.sol`) that the pass reads.
interface IKimJongUnRegistry {
    function hasPiggedAndFuckedKimJongUn(address account) external view returns (bool);
}

/// @title DPRK.FUN Not-Lazarus Pass ("김정은 개새끼" pass)
/// @notice Soulbound ERC-721 (ERC-5192, always locked). Any address that has called both `pig()` and `fuck()` on
/// the KimJongUn registry can claim one pass. It can't be transferred, approved, or burned, so certification is
/// permanent. The token URI is fully on-chain: base64 JSON whose `image` is a base64 SVG poster.
contract DprkPass is ERC721, IDprkPass {
    /// @dev ERC-5192 interface id.
    bytes4 private constant _ERC5192_INTERFACE_ID = 0xb45a3c0e;

    /// @inheritdoc IDprkPass
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable kimJongUn;
    /// @inheritdoc IDprkPass
    uint256 public totalClaimed;
    /// @inheritdoc IDprkPass
    mapping(address account => uint256 tokenId) public passOf;

    /// @notice Constructor argument was the zero address or had no code.
    error InvalidRegistry();

    constructor(address kimJongUn_, string memory name_, string memory symbol_) ERC721(name_, symbol_) {
        if (kimJongUn_.code.length == 0) revert InvalidRegistry();
        kimJongUn = kimJongUn_;
    }

    // ------------------------------------------------------------------------------------------------ claim

    /// @inheritdoc IDprkPass
    function claim() external returns (uint256 tokenId) {
        if (passOf[msg.sender] != 0) revert AlreadyCertified(msg.sender);
        if (!IKimJongUnRegistry(kimJongUn).hasPiggedAndFuckedKimJongUn(msg.sender)) {
            revert NotPiggedAndFucked(msg.sender);
        }
        tokenId = ++totalClaimed;
        passOf[msg.sender] = tokenId;
        // Plain `_mint`: a soulbound token can never leave the receiver, so the onERC721Received check that
        // `_safeMint` adds would protect nothing and would hand control to the caller mid-claim.
        _mint(msg.sender, tokenId);
        emit Locked(tokenId);
        emit PassClaimed(msg.sender, tokenId);
    }

    /// @inheritdoc IDprkPass
    function isCertified(address account) external view returns (bool) {
        return passOf[account] != 0;
    }

    // ------------------------------------------------------------------------------------------------ soulbound

    /// @notice ERC-5192: every pass is locked forever. Reverts for a token that doesn't exist.
    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    /// @dev Soulbound, enforced at OpenZeppelin's internal hooks so the public ABI stays standard ERC-721.
    /// Every transfer path (`transferFrom` and both `safeTransferFrom`s) of an existing pass reaches `_update` and
    /// reverts with `Soulbound()`, whoever the caller is. Mints (from == 0) are the only balance changes allowed.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    /// @dev `approve` always reverts. `_update` only clears approvals on transfers, which can't happen.
    function _approve(address, uint256, address, bool) internal pure override {
        revert Soulbound();
    }

    /// @dev `setApprovalForAll` always reverts.
    function _setApprovalForAll(address, address, bool) internal pure override {
        revert Soulbound();
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == _ERC5192_INTERFACE_ID || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------------------------------------ metadata

    /// @notice `data:application/json;base64,...` with an on-chain SVG poster as `image`.
    function tokenURI(uint256 tokenId) public view override(ERC721, IERC721Metadata) returns (string memory) {
        address holder = _requireOwned(tokenId);
        string memory id = Strings.toString(tokenId);
        string memory holderHex = Strings.toHexString(holder);

        string memory svg = string.concat(_SVG_HEAD, id, _SVG_MIDDLE, _shortAddress(holderHex), "</text></svg>");

        string memory json = string.concat(
            '{"name":"',
            _escapeJson(name()),
            " #",
            id,
            '","description":"',
            _DESCRIPTION,
            '","external_url":"https://dprk.fun/launchpad","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","attributes":[{"trait_type":"Holder","value":"',
            holderHex,
            _ATTRIBUTES,
            id,
            "}]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @dev "0x1234…abcd" from a 42-character lowercase hex address.
    function _shortAddress(string memory hexAddress) private pure returns (string memory) {
        bytes memory a = bytes(hexAddress);
        return string.concat(
            string(abi.encodePacked(a[0], a[1], a[2], a[3], a[4], a[5])),
            unicode"…",
            string(abi.encodePacked(a[38], a[39], a[40], a[41]))
        );
    }

    /// @dev Escapes `"`, `\` and control characters so a deployer-chosen collection name can't break the JSON.
    function _escapeJson(string memory value) private pure returns (string memory) {
        bytes memory input = bytes(value);
        uint256 extra;
        for (uint256 i; i < input.length; ++i) {
            bytes1 c = input[i];
            if (c == '"' || c == "\\") extra += 1;
            else if (uint8(c) < 0x20) extra += 5;
        }
        if (extra == 0) return value;

        bytes memory out = new bytes(input.length + extra);
        bytes16 hexSymbols = "0123456789abcdef";
        uint256 j;
        for (uint256 i; i < input.length; ++i) {
            bytes1 c = input[i];
            if (c == '"' || c == "\\") {
                out[j++] = "\\";
                out[j++] = c;
            } else if (uint8(c) < 0x20) {
                out[j++] = "\\";
                out[j++] = "u";
                out[j++] = "0";
                out[j++] = "0";
                out[j++] = hexSymbols[uint8(c) >> 4];
                out[j++] = hexSymbols[uint8(c) & 0x0f];
            } else {
                out[j++] = c;
            }
        }
        return string(out);
    }

    string private constant _DESCRIPTION = unicode"Soulbound proof that this wallet called pig() and fuck() on the "
        unicode"KimJongUn registry. 김정은 개새끼. No DPRK operator insults the Supreme Leader on-chain, so this "
        unicode"address is certified Not-Lazarus. Gate pass for the DPRK.FUN launchpad. Non-transferable.";

    string private constant _ATTRIBUTES = unicode'"},{"trait_type":"pig()","value":"✓"},'
        unicode'{"trait_type":"fuck()","value":"✓"},{"trait_type":"Lazarus","value":"No"},'
        unicode'{"trait_type":"Soulbound","value":"Yes"},{"display_type":"number","trait_type":"Pass","value":';

    /// @dev 600x800 propaganda poster: sunburst, gold frame, flat-top pig, "김정은 개새끼", stamp, number, holder.
    string private constant _SVG_HEAD = unicode'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 800" width="600" height="800">'
        unicode'<defs><radialGradient id="g" cx="50%" cy="41%" r="75%"><stop offset="0" stop-color="#e3001b"/>'
        unicode'<stop offset="1" stop-color="#5c000e"/></radialGradient></defs>'
        unicode'<rect width="600" height="800" fill="url(#g)"/>'
        unicode'<path fill="#ffd23f" opacity=".17" d="M300 330L1000 330L987 467ZM300 330L947 598L882 719ZM300 330L795 '
        unicode"825L689 912ZM300 330L568 977L437 1017ZM300 330L300 1030L163 1017ZM300 330L32 977L-89 912ZM300 330L-195 "
        unicode"825L-282 719ZM300 330L-347 598L-387 467ZM300 330L-400 330L-387 193ZM300 330L-347 62L-282 -59ZM300 330L-195 "
        unicode"-165L-89 -252ZM300 330L32 -317L163 -357ZM300 330L300 -370L437 -357ZM300 330L568 -317L689 -252ZM300 330L795 "
        unicode'-165L882 -59ZM300 330L947 62L987 193Z"/>'
        unicode'<rect x="16" y="16" width="568" height="768" fill="none" stroke="#ffd23f" stroke-width="8"/>'
        unicode'<rect x="30" y="30" width="540" height="740" fill="none" stroke="#ffd23f" stroke-width="2"/>'
        unicode'<rect x="30" y="52" width="540" height="80" fill="#2a0006"/>'
        unicode'<path fill="#ffd23f" d="M84 76L88 87L99 87L90 94L93 105L84 98L75 105L78 94L69 87L80 87ZM516 76L520 87L531 '
        unicode'87L522 94L525 105L516 98L507 105L510 94L501 87L512 87Z"/>'
        unicode'<circle cx="300" cy="345" r="112" fill="#fff6e0" stroke="#ffd23f" stroke-width="8"/>'
        unicode'<path fill="#ff7f9c" stroke="#2a0006" stroke-width="5" stroke-linejoin="round" '
        unicode'd="M236 300L224 248L276 270ZM364 300L376 248L324 270Z"/>'
        unicode'<circle cx="300" cy="350" r="76" fill="#ff9fb4" stroke="#2a0006" stroke-width="5"/>'
        unicode'<path fill="#16070a" d="M231 322C222 268 258 268 300 268C342 268 378 268 369 322C356 296 330 292 300 '
        unicode'292C270 292 244 296 231 322Z"/>'
        unicode'<g fill="#2a0006"><circle cx="273" cy="334" r="8"/><circle cx="327" cy="334" r="8"/></g>'
        unicode'<ellipse cx="300" cy="370" rx="34" ry="23" fill="#ff7f9c" stroke="#2a0006" stroke-width="5"/>'
        unicode'<g fill="#2a0006"><ellipse cx="288" cy="370" rx="6" ry="9"/><ellipse cx="312" cy="370" rx="6" ry="9"/></g>'
        unicode'<g transform="translate(300 609) rotate(-5)"><rect x="-182" y="-35" width="364" height="70" rx="10" '
        unicode'fill="#2a0006" fill-opacity=".35" stroke="#fff6e0" stroke-width="5"/><text y="13" text-anchor="middle" '
        unicode'font-family="Courier New,Courier,DejaVu Sans Mono,monospace" font-weight="700" font-size="34" '
        unicode'fill="#fff6e0">pig() ✓ fuck() ✓</text></g>'
        unicode'<text x="300" y="540" text-anchor="middle" font-family="Noto Sans KR,Noto Sans CJK KR,Apple SD Gothic Neo,'
        unicode'Malgun Gothic,sans-serif" font-weight="900" font-size="74" fill="#ffd23f" stroke="#2a0006" '
        unicode'stroke-width="4" paint-order="stroke">김정은 개새끼</text>'
        unicode'<g text-anchor="middle" font-family="Impact,Arial Black,Helvetica Neue,Arial,sans-serif" font-weight="900" '
        unicode'fill="#ffd23f"><text x="300" y="112" font-size="56" letter-spacing="6">DPRK.FUN</text>'
        unicode'<text x="300" y="190" font-size="46" letter-spacing="3" fill="#fff6e0">NOT-LAZARUS PASS</text>'
        unicode'<text x="300" y="768" font-size="14" letter-spacing="2">CERTIFIED NOT A NORTH KOREAN HACKER '
        unicode'· SOULBOUND</text><text x="300" y="712" font-size="54">#';

    string private constant _SVG_MIDDLE = '</text></g><text x="300" y="742" text-anchor="middle" '
        'font-family="Courier New,Courier,DejaVu Sans Mono,monospace" font-weight="700" font-size="20" '
        'fill="#fff6e0">';
}
