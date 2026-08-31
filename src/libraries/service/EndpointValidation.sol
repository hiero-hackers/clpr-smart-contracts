// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";

/// @title EndpointValidation
/// @notice Validates the discovery fields of a `ClprTypes.Endpoint`: IP addresses must be numeric
///         IPv4 or IPv6 (never DNS names), TLS certificates must be DER-encoded X.509 carrying an
///         RSA key of at least 2048 bits. Both fields are optional, so empty passes.
library EndpointValidation {
    // ASN.1 DER tags encountered while walking an X.509 certificate.
    uint8 private constant TAG_INTEGER = 0x02;
    uint8 private constant TAG_BIT_STRING = 0x03;
    uint8 private constant TAG_OID = 0x06;
    uint8 private constant TAG_SEQUENCE = 0x30;
    uint8 private constant TAG_CONTEXT_0 = 0xa0;

    /// @dev A 2048-bit RSA modulus is 256 bytes.
    uint256 private constant MIN_RSA_MODULUS_BYTES = 256;

    /// @notice Validate `ip` is a numeric IPv4 (`a.b.c.d`, each octet 0-255) or IPv6 (hex groups
    ///         separated by colons, optionally abbreviated with `::`).
    function validateIpAddress(string calldata ip) internal pure {
        bytes calldata b = bytes(ip);
        if (b.length == 0) return;

        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ":") {
                _validateIPv6(b);
                return;
            }
        }
        _validateIPv4(b);
    }

    /// @notice Validate `cert` is a DER-encoded X.509 certificate carrying an RSA public key.
    function validateTlsCertificate(bytes calldata cert) internal pure {
        if (cert.length == 0) return;
        _validateRsaDerCert(cert);
    }

    // ── IP addresses ──────────────────────────────────────────────────

    function _validateIPv4(bytes calldata b) private pure {
        uint256 dotCount = 0;
        uint256 octet = 0;
        uint256 digitCount = 0;

        for (uint256 i = 0; i <= b.length; i++) {
            bool atEnd = (i == b.length);
            if (atEnd || b[i] == ".") {
                if (digitCount == 0 || octet > 255) revert ClprTypes.ClprInvalidEndpointAddress();
                if (!atEnd) dotCount++;
                octet = 0;
                digitCount = 0;
            } else {
                bytes1 c = b[i];
                // Three digits max per octet: bounds `octet` and rejects e.g. "1234.0.0.1".
                if (c < "0" || c > "9" || digitCount >= 3) revert ClprTypes.ClprInvalidEndpointAddress();
                octet = octet * 10 + (uint8(c) - 0x30);
                digitCount++;
            }
        }
        if (dotCount != 3) revert ClprTypes.ClprInvalidEndpointAddress();
    }

    /// @dev Counts groups rather than colons :
    function _validateIPv6(bytes calldata b) private pure {
        uint256 n = b.length;
        uint256 groupCount = 0;
        uint256 groupLen = 0; // hex digits in the group being read
        bool hasDoubleColon = false;
        bool pendingColon = false; // a colon closed a group and has no group after it yet
        uint256 start = 0;

        // A leading colon is only legal as the first half of "::".
        if (b[0] == ":") {
            if (n < 2 || b[1] != ":") revert ClprTypes.ClprInvalidEndpointAddress();
            hasDoubleColon = true;
            start = 2;
        }

        for (uint256 i = start; i < n; i++) {
            bytes1 c = b[i];
            if (c != ":") {
                if (!_isHexChar(c)) revert ClprTypes.ClprInvalidEndpointAddress();
                groupLen++;
                pendingColon = false;
            } else if (groupLen != 0) {
                // This colon closes a group of 1-4 hex digits, and may open a "::".
                if (groupLen > 4) revert ClprTypes.ClprInvalidEndpointAddress();
                groupCount++;
                groupLen = 0;
                pendingColon = true;
            } else if (pendingColon) {
                // Second consecutive colon: the "::" abbreviation, allowed once.
                if (hasDoubleColon) revert ClprTypes.ClprInvalidEndpointAddress();
                hasDoubleColon = true;
                pendingColon = false;
            } else {
                revert ClprTypes.ClprInvalidEndpointAddress(); // empty group
            }
        }
        // A trailing single colon ("2001:db8:") never closes the address.
        if (pendingColon || groupLen > 4) revert ClprTypes.ClprInvalidEndpointAddress();
        if (groupLen != 0) groupCount++;

        // "::" stands for at least one all-zero group, so it leaves room for at most 7 explicit
        // ones; without it all 8 groups must be written out.
        if (hasDoubleColon ? groupCount > 7 : groupCount != 8) {
            revert ClprTypes.ClprInvalidEndpointAddress();
        }
    }

    function _isHexChar(bytes1 c) private pure returns (bool) {
        return (c >= "0" && c <= "9") || (c >= "A" && c <= "F") || (c >= "a" && c <= "f");
    }

    // ── DER RSA certificate ───────────────────────────────────────────

    /// @dev Walks Certificate → TBSCertificate → subjectPublicKeyInfo → algorithm (must be the
    ///      rsaEncryption OID) → subjectPublicKey → RSAPublicKey → modulus, and checks the modulus
    ///      length. This is a structural and key-strength check only; no signature is verified.
    function _validateRsaDerCert(bytes calldata cert) private pure {
        (uint256 pos,) = _enterSeq(cert, 0); // Certificate

        uint256 tbsEnd;
        (pos, tbsEnd) = _enterSeq(cert, pos); // TBSCertificate

        // version [0] EXPLICIT is optional (present in v2/v3 certificates).
        if (pos < tbsEnd && uint8(cert[pos]) == TAG_CONTEXT_0) pos = _skipTLV(cert, pos);

        pos = _skipTagged(cert, pos, TAG_INTEGER); // serialNumber
        pos = _skipTagged(cert, pos, TAG_SEQUENCE); // signature
        pos = _skipTagged(cert, pos, TAG_SEQUENCE); // issuer
        pos = _skipTagged(cert, pos, TAG_SEQUENCE); // validity
        pos = _skipTagged(cert, pos, TAG_SEQUENCE); // subject

        (uint256 spkiPos, uint256 spkiEnd) = _enterSeq(cert, pos); // subjectPublicKeyInfo
        (uint256 algoPos, uint256 algoEnd) = _enterSeq(cert, spkiPos); // algorithm

        // The algorithm OID must be rsaEncryption: 2a 86 48 86 f7 0d 01 01 01.
        if (algoPos >= algoEnd || uint8(cert[algoPos]) != TAG_OID) {
            revert ClprTypes.ClprInvalidEndpointCertificate();
        }
        uint256 oidLen;
        (oidLen, algoPos) = _readLength(cert, algoPos + 1);
        if (oidLen != 9) revert ClprTypes.ClprInvalidEndpointCertificate();
        if (
            cert[algoPos] != 0x2a || cert[algoPos + 1] != 0x86 || cert[algoPos + 2] != 0x48 || cert[algoPos + 3] != 0x86
                || cert[algoPos + 4] != 0xf7 || cert[algoPos + 5] != 0x0d || cert[algoPos + 6] != 0x01
                || cert[algoPos + 7] != 0x01 || cert[algoPos + 8] != 0x01
        ) revert ClprTypes.ClprInvalidEndpointCertificate();

        // subjectPublicKey BIT STRING; its first content byte is the unused-bit count, which must be 0.
        if (algoEnd >= spkiEnd || uint8(cert[algoEnd]) != TAG_BIT_STRING) {
            revert ClprTypes.ClprInvalidEndpointCertificate();
        }
        (uint256 bsLen, uint256 bsContentPos) = _readLength(cert, algoEnd + 1);
        if (bsLen == 0 || uint8(cert[bsContentPos]) != 0x00) revert ClprTypes.ClprInvalidEndpointCertificate();

        (uint256 rsaContentPos,) = _enterSeq(cert, bsContentPos + 1); // RSAPublicKey

        if (rsaContentPos >= cert.length || uint8(cert[rsaContentPos]) != TAG_INTEGER) {
            revert ClprTypes.ClprInvalidEndpointCertificate();
        }
        (uint256 modLen,) = _readLength(cert, rsaContentPos + 1); // modulus
        if (modLen < MIN_RSA_MODULUS_BYTES) revert ClprTypes.ClprInvalidEndpointCertificate();
    }

    // ── DER utilities ─────────────────────────────────────────────────

    function _readLength(bytes calldata data, uint256 pos) private pure returns (uint256 len, uint256 newPos) {
        if (pos >= data.length) revert ClprTypes.ClprInvalidEndpointCertificate();
        uint8 first = uint8(data[pos]);
        if (first < 0x80) {
            len = first;
            newPos = pos + 1;
        } else if (first == 0x81) {
            if (pos + 1 >= data.length) revert ClprTypes.ClprInvalidEndpointCertificate();
            len = uint8(data[pos + 1]);
            newPos = pos + 2;
        } else if (first == 0x82) {
            if (pos + 2 >= data.length) revert ClprTypes.ClprInvalidEndpointCertificate();
            len = (uint256(uint8(data[pos + 1])) << 8) | uint256(uint8(data[pos + 2]));
            newPos = pos + 3;
        } else {
            revert ClprTypes.ClprInvalidEndpointCertificate();
        }
        if (newPos + len > data.length) revert ClprTypes.ClprInvalidEndpointCertificate();
    }

    /// @dev Skips the TLV starting at `pos`. `_readLength` bounds-checks `pos + 1`, so callers only
    ///      need to have established that the tag byte at `pos` is readable.
    function _skipTLV(bytes calldata data, uint256 pos) private pure returns (uint256) {
        (uint256 len, uint256 contentPos) = _readLength(data, pos + 1);
        return contentPos + len;
    }

    function _skipTagged(bytes calldata data, uint256 pos, uint8 expectedTag) private pure returns (uint256) {
        if (pos >= data.length || uint8(data[pos]) != expectedTag) {
            revert ClprTypes.ClprInvalidEndpointCertificate();
        }
        return _skipTLV(data, pos);
    }

    /// @dev Returns the first byte of the SEQUENCE content at `pos`, and the first byte past it.
    function _enterSeq(bytes calldata data, uint256 pos)
        private
        pure
        returns (uint256 contentStart, uint256 contentEnd)
    {
        if (pos >= data.length || uint8(data[pos]) != TAG_SEQUENCE) {
            revert ClprTypes.ClprInvalidEndpointCertificate();
        }
        uint256 len;
        (len, contentStart) = _readLength(data, pos + 1);
        contentEnd = contentStart + len;
    }
}
