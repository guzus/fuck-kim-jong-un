// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test-only standard base64 decoder (RFC 4648, with padding). Reverts on malformed input, which makes
/// it a strict check that `tokenURI` emits well-formed base64.
library Base64Decode {
    function decode(string memory input) internal pure returns (bytes memory out) {
        bytes memory data = bytes(input);
        require(data.length % 4 == 0, "base64: length");
        if (data.length == 0) return out;

        uint256 padding;
        if (data[data.length - 1] == "=") padding++;
        if (data[data.length - 2] == "=") padding++;

        out = new bytes(data.length / 4 * 3 - padding);
        uint256 o;
        for (uint256 i; i < data.length; i += 4) {
            uint256 n = (_value(data[i]) << 18) | (_value(data[i + 1]) << 12);
            bool pad2 = data[i + 2] == "=";
            bool pad3 = data[i + 3] == "=";
            require(!pad2 || pad3, "base64: padding");
            require(!(pad2 || pad3) || i + 4 == data.length, "base64: early padding");
            if (!pad2) n |= _value(data[i + 2]) << 6;
            if (!pad3) n |= _value(data[i + 3]);

            out[o++] = bytes1(uint8(n >> 16));
            if (!pad2) out[o++] = bytes1(uint8(n >> 8));
            if (!pad3) out[o++] = bytes1(uint8(n));
        }
    }

    function _value(bytes1 c) private pure returns (uint256) {
        uint8 x = uint8(c);
        if (x >= 65 && x <= 90) return x - 65; // A-Z
        if (x >= 97 && x <= 122) return x - 71; // a-z
        if (x >= 48 && x <= 57) return x + 4; // 0-9
        if (x == 43) return 62; // +
        if (x == 47) return 63; // /
        revert("base64: character");
    }

    /// @dev Returns `s` without `prefix`, reverting if `s` doesn't start with it.
    function stripPrefix(string memory s, string memory prefix) internal pure returns (string memory rest) {
        bytes memory b = bytes(s);
        bytes memory p = bytes(prefix);
        require(b.length >= p.length, "prefix: too short");
        for (uint256 i; i < p.length; ++i) {
            require(b[i] == p[i], "prefix: mismatch");
        }
        bytes memory r = new bytes(b.length - p.length);
        for (uint256 i; i < r.length; ++i) {
            r[i] = b[i + p.length];
        }
        return string(r);
    }
}
