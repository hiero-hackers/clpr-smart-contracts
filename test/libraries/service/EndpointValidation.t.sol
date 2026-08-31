// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";
import {EndpointValidation} from "@hiero-ledger/clpr/libraries/service/EndpointValidation.sol";
import {ClprTestBase} from "@test/helpers/ClprTestBase.sol";

// ── Harness ────────────────────────────────────────────────────────────────
// Wraps internal library functions so they can be invoked as external calls
// in tests (enabling vm.expectRevert and try/catch).

contract EndpointValidationHarness {
    function validateIpAddress(string calldata ip) external pure {
        EndpointValidation.validateIpAddress(ip);
    }

    function validateTlsCertificate(bytes calldata cert) external pure {
        EndpointValidation.validateTlsCertificate(cert);
    }
}

// ── DER certificate builder ───────────────────────────────────────────────
// Builds minimal but structurally correct DER X.509 certificates for testing.
// The certificates are not signed and would never be used in production.

abstract contract DerCertBuilder {
    function _encLen(uint256 len) internal pure returns (bytes memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        if (len < 0x80) return abi.encodePacked(uint8(len));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (len < 0x100) return abi.encodePacked(uint8(0x81), uint8(len));
        // forge-lint: disable-next-line(unsafe-typecast)
        return abi.encodePacked(uint8(0x82), uint8(len >> 8), uint8(len & 0xff));
    }

    function _tlv(uint8 tag, bytes memory content) internal pure returns (bytes memory) {
        return bytes.concat(abi.encodePacked(tag), _encLen(content.length), content);
    }

    /// @dev Construct a minimal DER X.509 certificate with an RSA key whose
    ///      modulus has exactly `modulusByteLen` bytes (all 0x01).
    ///      modulusByteLen=256 → RSA-2048, 128 → RSA-1024, 512 → RSA-4096.
    function _buildRsaCert(uint256 modulusByteLen) internal pure returns (bytes memory) {
        // Modulus: all 0x01 (first byte non-zero, so no DER sign prefix needed)
        bytes memory modulus = new bytes(modulusByteLen);
        for (uint256 i = 0; i < modulusByteLen; i++) {
            modulus[i] = 0x01;
        }

        // RSAPublicKey SEQUENCE { INTEGER(modulus), INTEGER(65537) }
        bytes memory rsaKey = _tlv(0x30, bytes.concat(_tlv(0x02, modulus), hex"0203010001"));

        // subjectPublicKeyInfo SEQUENCE {
        //   algorithm SEQUENCE { OID(rsaEncryption), NULL }
        //   BIT STRING { 0x00 (unused bits), RSAPublicKey }
        // }
        bytes memory spki = _tlv(
            0x30,
            bytes.concat(
                _tlv(0x30, bytes.concat(hex"06092a864886f70d010101", hex"0500")),
                _tlv(0x03, bytes.concat(hex"00", rsaKey))
            )
        );

        // TBSCertificate SEQUENCE
        bytes memory tbs = _tlv(
            0x30,
            bytes.concat(
                hex"a003020102", // version [0] EXPLICIT INTEGER(2) = v3
                hex"020101", // serialNumber INTEGER(1)
                _tlv(0x30, bytes.concat(hex"06092a864886f70d01010b", hex"0500")), // signature sha256WithRSA
                hex"3000", // issuer (empty SEQUENCE)
                _tlv(
                    0x30,
                    bytes.concat(
                        hex"170d3230303130313030303030305a", // notBefore 200101000000Z
                        hex"170d3239313233313233353935395a" // notAfter  291231235959Z
                    )
                ),
                hex"3000", // subject (empty SEQUENCE)
                spki
            )
        );

        // Certificate SEQUENCE { TBSCertificate, signatureAlgorithm, signature }
        return _tlv(
            0x30,
            bytes.concat(
                tbs,
                _tlv(0x30, bytes.concat(hex"06092a864886f70d01010b", hex"0500")), // signatureAlgorithm
                hex"03020001" // signature BIT STRING (1 byte, 0 unused bits)
            )
        );
    }

    /// @dev Same structure as _buildRsaCert but with the EC public key OID
    ///      (id-ecPublicKey: 2a 86 48 ce 3d 02 01, 7 bytes) instead of rsaEncryption.
    function _buildEcCert() internal pure returns (bytes memory) {
        bytes memory ecKey = new bytes(65);
        ecKey[0] = 0x04; // uncompressed EC point

        bytes memory spki = _tlv(
            0x30,
            bytes.concat(
                _tlv(0x30, bytes.concat(hex"06072a8648ce3d0201", hex"0500")), // EC OID
                _tlv(0x03, bytes.concat(hex"00", ecKey))
            )
        );

        bytes memory tbs = _tlv(
            0x30,
            bytes.concat(
                hex"a003020102",
                hex"020101",
                _tlv(0x30, bytes.concat(hex"06092a864886f70d01010b", hex"0500")),
                hex"3000",
                _tlv(0x30, bytes.concat(hex"170d3230303130313030303030305a", hex"170d3239313233313233353935395a")),
                hex"3000",
                spki
            )
        );

        return
            _tlv(
                0x30, bytes.concat(tbs, _tlv(0x30, bytes.concat(hex"06092a864886f70d01010b", hex"0500")), hex"03020001")
            );
    }
}

// ── IP address validation tests ───────────────────────────────────────────

contract EndpointValidation_IpTest is Test {
    EndpointValidationHarness harness;

    function setUp() public {
        harness = new EndpointValidationHarness();
    }

    // ── Valid IPv4 ──────────────────────────────────────────────────────

    function test_ip_valid_typical() public view {
        harness.validateIpAddress("192.168.1.1");
    }

    function test_ip_valid_loopback() public view {
        harness.validateIpAddress("127.0.0.1");
    }

    function test_ip_valid_allZeros() public view {
        harness.validateIpAddress("0.0.0.0");
    }

    function test_ip_valid_broadcast() public view {
        harness.validateIpAddress("255.255.255.255");
    }

    function test_ip_valid_singleDigitOctets() public view {
        harness.validateIpAddress("1.2.3.4");
    }

    function test_ip_valid_empty() public view {
        harness.validateIpAddress("");
    }

    // ── Valid IPv6 ──────────────────────────────────────────────────────

    function test_ip_valid_ipv6_loopback() public view {
        harness.validateIpAddress("::1");
    }

    function test_ip_valid_ipv6_allZeros() public view {
        harness.validateIpAddress("::");
    }

    function test_ip_valid_ipv6_full() public view {
        harness.validateIpAddress("2001:0db8:85a3:0000:0000:8a2e:0370:7334");
    }

    function test_ip_valid_ipv6_compressed() public view {
        harness.validateIpAddress("fe80::1");
    }

    function test_ip_valid_ipv6_uppercase() public view {
        harness.validateIpAddress("FE80::1");
    }

    function test_ip_valid_ipv6_trailingDoubleColon() public view {
        harness.validateIpAddress("2001:db8::");
    }

    // ── Invalid: DNS names ──────────────────────────────────────────────

    function test_ip_revert_dns_hostname() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("example.com");
    }

    function test_ip_revert_dns_local() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("hostname.local");
    }

    function test_ip_revert_dns_subdomain() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("peer.network.internal");
    }

    function test_ip_revert_dns_withHyphen() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("my-node.example.com");
    }

    // ── Invalid IPv4 ────────────────────────────────────────────────────

    function test_ip_revert_octetTooLarge() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("256.0.0.1");
    }

    function test_ip_revert_tooFewOctets() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("192.168.1");
    }

    function test_ip_revert_tooManyOctets() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("192.168.1.1.1");
    }

    function test_ip_revert_emptyOctet() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("192..168.1");
    }

    function test_ip_revert_trailingDot() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("192.168.1.1.");
    }

    function test_ip_revert_leadingDot() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress(".192.168.1.1");
    }

    function test_ip_revert_alphaInOctet() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("192.168.a.1");
    }

    function test_ip_revert_justNumber() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("192");
    }

    // ── Invalid IPv6 ────────────────────────────────────────────────────

    function test_ip_revert_ipv6_invalidChar() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("xyz::1");
    }

    function test_ip_revert_ipv6_withPercent() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("fe80::1%eth0");
    }

    function test_ip_revert_ipv6_trailingColon() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("2001:db8:");
    }

    function test_ip_revert_ipv6_multipleDoubleColon() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("::1::2");
    }

    function test_ip_revert_ipv6_tooFewColonsNoDoubleColon() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("2001:db8:85a3"); // only 2 colons, no ::
    }

    function test_ip_revert_ipv6_groupTooLong() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("::12345"); // group has 5 hex chars
    }

    // ── Invalid IPv6: empty groups ──────────────────────────────────────

    function test_ip_revert_ipv6_tripleColon_bare() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress(":::");
    }

    function test_ip_revert_ipv6_tripleColon_betweenGroups() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("1:::2");
    }

    function test_ip_revert_ipv6_quadColon() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("::::");
    }

    function test_ip_revert_ipv6_emptyGroupAfterDoubleColon() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("1::2:::3");
    }

    function test_ip_revert_ipv6_leadingSingleColon() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress(":1:2:3:4:5:6:7");
    }

    function test_ip_revert_ipv6_onlyColon() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress(":");
    }

    // ── Invalid IPv6: group count ───────────────────────────────────────

    /// @dev 8 explicit groups plus a "::" that must expand to at least one more.
    function test_ip_revert_ipv6_doubleColonWithEightGroups() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("1::2:3:4:5:6:7:8");
    }

    function test_ip_revert_ipv6_nineGroupsNoDoubleColon() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("1:2:3:4:5:6:7:8:9");
    }

    function test_ip_revert_ipv6_sevenGroupsNoDoubleColon() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("1:2:3:4:5:6:7");
    }

    function test_ip_revert_ipv6_trailingSingleColonAfterEightGroups() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("1:2:3:4:5:6:7:8:");
    }

    function test_ip_revert_ipv6_twoDoubleColons() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("1::2::3");
    }

    /// @dev The IPv4-mapped dotted form is deliberately not supported.
    function test_ip_revert_ipv6_ipv4Mapped() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("::ffff:192.0.2.1");
    }

    // ── Valid IPv6: boundaries the tightened rules must still admit ─────

    /// @dev "::" collapsing exactly one group leaves 7 explicit ones — the upper bound.
    function test_ip_valid_ipv6_sevenGroupsWithDoubleColon() public view {
        harness.validateIpAddress("1:2:3:4:5:6:7::");
    }

    function test_ip_valid_ipv6_leadingDoubleColonSevenGroups() public view {
        harness.validateIpAddress("::2:3:4:5:6:7:8");
    }

    function test_ip_valid_ipv6_doubleColonInMiddle() public view {
        harness.validateIpAddress("2001:db8::8a2e:370:7334");
    }

    function test_ip_valid_ipv6_singleGroupAfterDoubleColon() public view {
        harness.validateIpAddress("::ffff");
    }

    function test_ip_valid_ipv6_mixedCase() public view {
        harness.validateIpAddress("2001:0DB8:85a3:0000:0000:8A2E:0370:7334");
    }

    function test_ip_valid_ipv6_fourDigitGroups() public view {
        harness.validateIpAddress("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff");
    }
}

// ── TLS certificate validation tests ─────────────────────────────────────

contract EndpointValidation_CertTest is Test, DerCertBuilder {
    EndpointValidationHarness harness;

    function setUp() public {
        harness = new EndpointValidationHarness();
    }

    // ── DER cert corruption ─────────────────────────────────────────────────

    /// @dev Wrap an arbitrary subjectPublicKeyInfo into an otherwise-valid certificate.
    function _certWithSpki(bytes memory spki) internal pure returns (bytes memory) {
        bytes memory tbs = _tlv(
            0x30,
            bytes.concat(
                hex"a003020102", // version [0] EXPLICIT INTEGER(2) = v3
                hex"020101", // serialNumber
                _tlv(0x30, bytes.concat(hex"06092a864886f70d01010b", hex"0500")), // signature algo
                hex"3000", // issuer
                _tlv(0x30, bytes.concat(hex"170d3230303130313030303030305a", hex"170d3239313233313233353935395a")),
                hex"3000", // subject
                spki
            )
        );
        return
            _tlv(
                0x30, bytes.concat(tbs, _tlv(0x30, bytes.concat(hex"06092a864886f70d01010b", hex"0500")), hex"03020001")
            );
    }

    function _rsaSpkiWith(bytes memory algo, bytes memory subjectPublicKey) internal pure returns (bytes memory) {
        return _tlv(0x30, bytes.concat(algo, subjectPublicKey));
    }

    function _validRsaKeyBitstring() internal pure returns (bytes memory) {
        bytes memory modulus = new bytes(256);
        modulus[0] = 0x01;
        bytes memory rsaKey = _tlv(0x30, bytes.concat(_tlv(0x02, modulus), hex"0203010001"));
        return _tlv(0x03, bytes.concat(hex"00", rsaKey));
    }

    function _assertCertReverts(bytes memory cert) internal {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointCertificate.selector);
        harness.validateTlsCertificate(cert);
    }

    // ── Valid ────────────────────────────────────────────────────────────

    function test_cert_valid_empty() public view {
        harness.validateTlsCertificate(hex"");
    }

    function test_cert_valid_rsa2048() public view {
        bytes memory cert = _buildRsaCert(256); // 256 bytes = 2048 bits
        harness.validateTlsCertificate(cert);
    }

    function test_cert_valid_rsa4096() public view {
        bytes memory cert = _buildRsaCert(512); // 512 bytes = 4096 bits
        harness.validateTlsCertificate(cert);
    }

    function test_cert_valid_rsa2048_withSignPrefix() public view {
        // DER modulus with leading 0x00 (sign byte) + 256 bytes → modLen = 257 ≥ 256
        bytes memory cert = _buildRsaCert(257);
        harness.validateTlsCertificate(cert);
    }

    // ── Invalid: too-small key ───────────────────────────────────────────

    function test_cert_revert_rsa1024() public {
        bytes memory cert = _buildRsaCert(128); // 128 bytes = 1024 bits
        vm.expectRevert(ClprTypes.ClprInvalidEndpointCertificate.selector);
        harness.validateTlsCertificate(cert);
    }

    function test_cert_revert_rsa512() public {
        bytes memory cert = _buildRsaCert(64); // 64 bytes = 512 bits
        vm.expectRevert(ClprTypes.ClprInvalidEndpointCertificate.selector);
        harness.validateTlsCertificate(cert);
    }

    function test_cert_revert_rsa2047() public {
        // 255 bytes = 2040 bits < 2048
        bytes memory cert = _buildRsaCert(255);
        vm.expectRevert(ClprTypes.ClprInvalidEndpointCertificate.selector);
        harness.validateTlsCertificate(cert);
    }

    // ── Invalid: structure ───────────────────────────────────────────────

    function test_cert_revert_notSequence() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointCertificate.selector);
        harness.validateTlsCertificate(hex"deadbeef");
    }

    function test_cert_revert_truncated() public {
        bytes memory cert = _buildRsaCert(256);
        // Cut to first 10 bytes — navigation will fail
        bytes memory truncated = new bytes(10);
        for (uint256 i = 0; i < 10; i++) {
            truncated[i] = cert[i];
        }
        vm.expectRevert(ClprTypes.ClprInvalidEndpointCertificate.selector);
        harness.validateTlsCertificate(truncated);
    }

    function test_cert_revert_ecKey() public {
        // Certificate uses an EC public key OID instead of rsaEncryption
        bytes memory cert = _buildEcCert();
        vm.expectRevert(ClprTypes.ClprInvalidEndpointCertificate.selector);
        harness.validateTlsCertificate(cert);
    }

    function test_cert_revert_garbage() public {
        bytes memory garbage = new bytes(400);
        for (uint256 i = 0; i < garbage.length; i++) {
            garbage[i] = 0x30;
        }
        vm.expectRevert();
        harness.validateTlsCertificate(garbage);
    }

    function test_cert_revert_singleByte() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointCertificate.selector);
        harness.validateTlsCertificate(hex"30");
    }

    // ── IPv4 ────────────────────────────────────────────────────────────────

    function test_ipv4_fourDigitOctet_reverts() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("1234.0.0.1");
    }

    // ── IPv6 ────────────────────────────────────────────────────────────────

    function test_ipv6_fullEightGroups_passes() public view {
        harness.validateIpAddress("1:2:3:4:5:6:7:8");
    }

    function test_ipv6_trailingDoubleColon_passes() public view {
        harness.validateIpAddress("1::");
    }

    function test_ipv6_groupTooLong_reverts() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("12345::1");
    }

    function test_ipv6_lastGroupTooLong_reverts() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("1::23456");
    }

    function test_ipv6_trailingSingleColon_reverts() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("2001:db8:");
    }

    function test_ipv6_doubleColonWithTooManyColons_reverts() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        harness.validateIpAddress("::1:2:3:4:5:6:7:8");
    }

    function test_cert_algorithmNotOid_reverts() public {
        // algorithm SEQUENCE containing NULL instead of an OID (first byte 0x05, not 0x06)
        _assertCertReverts(_certWithSpki(_rsaSpkiWith(_tlv(0x30, hex"0500"), _validRsaKeyBitstring())));
    }

    function test_cert_wrongOidContent_reverts() public {
        // 9-byte OID whose last byte differs from rsaEncryption
        _assertCertReverts(
            _certWithSpki(_rsaSpkiWith(_tlv(0x30, hex"06092a864886f70d010102"), _validRsaKeyBitstring()))
        );
    }

    function test_cert_missingBitString_reverts() public {
        // algorithm only — algoEnd reaches spkiEnd with no BIT STRING following
        _assertCertReverts(_certWithSpki(_rsaSpkiWith(_tlv(0x30, hex"06092a864886f70d010101"), "")));
    }

    function test_cert_emptyBitString_reverts() public {
        _assertCertReverts(_certWithSpki(_rsaSpkiWith(_tlv(0x30, hex"06092a864886f70d010101"), _tlv(0x03, ""))));
    }

    function test_cert_nonzeroUnusedBits_reverts() public {
        _assertCertReverts(_certWithSpki(_rsaSpkiWith(_tlv(0x30, hex"06092a864886f70d010101"), _tlv(0x03, hex"07AA"))));
    }

    function test_cert_modulusNotInteger_reverts() public {
        // RSAPublicKey SEQUENCE whose first element is an OCTET STRING, not INTEGER
        bytes memory rsaKey = _tlv(0x30, _tlv(0x04, hex"01"));
        bytes memory bitstring = _tlv(0x03, bytes.concat(hex"00", rsaKey));
        _assertCertReverts(_certWithSpki(_rsaSpkiWith(_tlv(0x30, hex"06092a864886f70d010101"), bitstring)));
    }

    // ── DER length-form truncations ─────────────────────────────────────────

    function test_cert_truncatedLongForm81_reverts() public {
        _assertCertReverts(hex"3081"); // 0x81 length form with no length byte
    }

    function test_cert_truncatedLongForm82_reverts() public {
        _assertCertReverts(hex"308200"); // 0x82 length form with only one of two length bytes
    }

    function test_cert_unsupportedLengthForm_reverts() public {
        _assertCertReverts(hex"3083000001"); // 3-byte length form is not DER for these sizes
    }

    function test_cert_truncatedAfterVersion_reverts() public {
        // TBSCertificate ends right after the version — the serialNumber skip runs off the end.
        _assertCertReverts(_tlv(0x30, _tlv(0x30, hex"a003020102")));
    }
}

// ── Fuzz tests ────────────────────────────────────────────────────────────

contract EndpointValidation_FuzzTest is Test, DerCertBuilder {
    EndpointValidationHarness harness;

    function setUp() public {
        harness = new EndpointValidationHarness();
    }

    /// @dev Any combination of four uint8 octets forms a valid IPv4 address.
    function testFuzz_ip_validIPv4_alwaysPasses(uint8 a, uint8 b, uint8 c, uint8 d) public view {
        string memory ip = string(
            abi.encodePacked(_uint8ToString(a), ".", _uint8ToString(b), ".", _uint8ToString(c), ".", _uint8ToString(d))
        );
        harness.validateIpAddress(ip); // must not revert
    }

    /// @dev Fuzzer generates random strings; the validator must never panic
    ///      (only revert with ClprInvalidEndpointAddress or succeed).
    function testFuzz_ip_randomString_noPanic(string memory ip) public view {
        try harness.validateIpAddress(ip) {}
        catch (bytes memory err) {
            if (err.length >= 4) {
                assertEq(
                    // forge-lint: disable-next-line(unsafe-typecast)
                    bytes4(err),
                    ClprTypes.ClprInvalidEndpointAddress.selector,
                    "unexpected revert selector from validateIpAddress"
                );
            }
        }
    }

    /// @dev Fuzzer generates random bytes; the validator must never panic.
    function testFuzz_cert_randomBytes_noPanic(bytes calldata cert) public view {
        try harness.validateTlsCertificate(cert) {}
        catch (bytes memory err) {
            if (err.length >= 4) {
                assertEq(
                    // forge-lint: disable-next-line(unsafe-typecast)
                    bytes4(err),
                    ClprTypes.ClprInvalidEndpointCertificate.selector,
                    "unexpected revert selector from validateTlsCertificate"
                );
            }
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    function _uint8ToString(uint8 v) internal pure returns (string memory) {
        if (v < 10) return string(abi.encodePacked(bytes1(0x30 + v)));
        if (v < 100) {
            return string(abi.encodePacked(bytes1(0x30 + v / 10), bytes1(0x30 + v % 10)));
        }
        return string(abi.encodePacked(bytes1(0x30 + v / 100), bytes1(0x30 + (v / 10) % 10), bytes1(0x30 + v % 10)));
    }
}

// ── Integration: updateLedgerConfiguration validates endpoint fields ───────

contract EndpointValidation_Integration is ClprTestBase, DerCertBuilder {
    function setUp() public override {
        _setUp(); // deploy service + config, no active channel needed
    }

    function _makeEndpoints(string memory ip, bytes memory cert)
        internal
        pure
        returns (ClprTypes.Endpoint[] memory eps)
    {
        eps = new ClprTypes.Endpoint[](1);
        eps[0] = ClprTypes.Endpoint({ipAddress: ip, port: 8080, tlsCertificate: cert, accountId: hex""});
    }

    /// @dev Endpoints now enter via the manifest (ManifestLib validates at every intake path);
    ///      a batch admission mirrors the old seed-endpoints array semantics.
    function _updateConfig(ClprTypes.Endpoint[] memory eps) internal {
        ClprTypes.ManifestUpdateEntry[] memory adds = new ClprTypes.ManifestUpdateEntry[](eps.length);
        for (uint256 i = 0; i < eps.length; i++) {
            // casting to 'uint160' is safe because tests admit at most two endpoints, so
            // 0xE000 + i stays far below type(uint160).max; it only fabricates distinct registrants.
            // forge-lint: disable-next-line(unsafe-typecast)
            adds[i] = ClprTypes.ManifestUpdateEntry({registrantAccount: address(uint160(0xE000 + i)), endpoint: eps[i]});
        }
        service.updateEndpointManifest(adds, new address[](0));
    }

    // ── Valid inputs pass ─────────────────────────────────────────────────

    function test_integration_emptyEndpoints_passes() public {
        service.updateEndpointManifest(new ClprTypes.ManifestUpdateEntry[](0), new address[](0));
    }

    function test_integration_validIPv4_emptyCert_passes() public {
        _updateConfig(_makeEndpoints("10.0.0.1", hex""));
    }

    function test_integration_validIPv4_rsa2048Cert_passes() public {
        _updateConfig(_makeEndpoints("10.0.0.1", _buildRsaCert(256)));
    }

    function test_integration_validIPv6_passes() public {
        _updateConfig(_makeEndpoints("::1", hex""));
    }

    function test_integration_emptyIP_emptyCert_passes() public {
        _updateConfig(_makeEndpoints("", hex""));
    }

    // ── Invalid IP rejects ────────────────────────────────────────────────

    function test_integration_revert_dnsName() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        _updateConfig(_makeEndpoints("example.com", hex""));
    }

    function test_integration_revert_invalidOctet() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        _updateConfig(_makeEndpoints("256.0.0.1", hex""));
    }

    function test_integration_revert_hostnameWithPort() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        _updateConfig(_makeEndpoints("peer.node.internal", hex""));
    }

    // ── Invalid cert rejects ──────────────────────────────────────────────

    function test_integration_revert_rsa1024Cert() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointCertificate.selector);
        _updateConfig(_makeEndpoints("10.0.0.1", _buildRsaCert(128)));
    }

    function test_integration_revert_invalidCertBytes() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointCertificate.selector);
        _updateConfig(_makeEndpoints("10.0.0.1", hex"deadbeef"));
    }

    function test_integration_revert_ecCert() public {
        vm.expectRevert(ClprTypes.ClprInvalidEndpointCertificate.selector);
        _updateConfig(_makeEndpoints("10.0.0.1", _buildEcCert()));
    }

    // ── First invalid endpoint in an array rejects the whole call ─────────

    function test_integration_revert_secondEndpointInvalid() public {
        ClprTypes.Endpoint[] memory eps = new ClprTypes.Endpoint[](2);
        eps[0] = ClprTypes.Endpoint({ipAddress: "10.0.0.1", port: 8080, tlsCertificate: hex"", accountId: hex""});
        eps[1] = ClprTypes.Endpoint({ipAddress: "bad.hostname", port: 8081, tlsCertificate: hex"", accountId: hex""});
        vm.expectRevert(ClprTypes.ClprInvalidEndpointAddress.selector);
        _updateConfig(eps);
    }
}
