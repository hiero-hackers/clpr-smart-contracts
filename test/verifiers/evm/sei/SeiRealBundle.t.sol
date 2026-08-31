// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SeiCometBftVerifier} from "@hiero-ledger/clpr/verifiers/evm/sei/SeiCometBftVerifier.sol";
import {Ed25519Verifier} from "@hiero-ledger/clpr/verifiers/evm/sei/Ed25519Verifier.sol";
import {SeiRealBundleFixtures} from "@test/verifiers/evm/sei/SeiRealBundleFixtures.sol";
import {CometBftLib} from "@hiero-ledger/clpr/libraries/proof/cometbft/CometBftLib.sol";
import {Ics23Lib} from "@hiero-ledger/clpr/libraries/proof/cometbft/Ics23Lib.sol";

/// @dev Exposes the verifier internals so we can replay the REAL relay bundle's signed-header
///      bytes (captured live from clpr-relay-sei1) and pinpoint where the Solidity reconstruction
///      diverges from the real CometBFT header/commit.
contract Harness is SeiCometBftVerifier {
    constructor(address ed) SeiCometBftVerifier(ed) {}

    function parseSignedHeader(bytes memory data)
        external
        pure
        returns (CometBftLib.SeiHeader memory h, CometBftLib.SeiCommit memory c)
    {
        return _parseSignedHeader(data);
    }

    function headerHash(CometBftLib.SeiHeader memory h) external pure returns (bytes32) {
        return CometBftLib.headerHash(h);
    }

    function precommitSignBytes(
        string memory chainId,
        int64 height,
        int32 round,
        bytes32 blockIdHash,
        uint32 partTotal,
        bytes32 partHash,
        int64 tsSec,
        int32 tsNanos
    ) external pure returns (bytes memory) {
        return CometBftLib.precommitSignBytes(chainId, height, round, blockIdHash, partTotal, partHash, tsSec, tsNanos);
    }

    function verifyEd(bytes32 pk, bytes memory msg_, bytes memory sig) external view returns (bool) {
        return _verifyEd25519(pk, msg_, sig);
    }

    function validatorSetHash(CometBftLib.SeiValidator[] memory v) external pure returns (bytes32) {
        return CometBftLib.validatorSetHash(v);
    }

    /// @dev Parses a real IAVL non-existence CommitmentProof, recomputes both neighbour roots, and
    ///      runs the full non-membership check against that root. Reverts if invalid.
    function checkNonMembership(bytes memory commitmentProof, bytes memory key)
        external
        pure
        returns (bytes32 leftRoot, bytes32 rightRoot)
    {
        (bool isExist,, Ics23Lib.NonExistenceProof memory nep) = _parseCommitmentProof(commitmentProof);
        require(!isExist, "expected non-existence proof");
        leftRoot = nep.hasLeft ? Ics23Lib.existenceRootIavl(nep.left) : bytes32(0);
        rightRoot = nep.hasRight ? Ics23Lib.existenceRootIavl(nep.right) : bytes32(0);
        Ics23Lib.verifyNonMembershipIavl(nep, leftRoot, key);
    }
}

contract SeiRealBundleTest is Test, SeiRealBundleFixtures {
    Harness h;

    function setUp() public {
        Ed25519Verifier ed = new Ed25519Verifier();
        CometBftLib.SeiValidator[] memory gv = new CometBftLib.SeiValidator[](1);
        gv[0] = CometBftLib.SeiValidator({ed25519PubKey: PUBKEY, votingPower: POWER});
        h = new Harness(address(ed));
    }

    function test_replayRealBundle() public view {
        (CometBftLib.SeiHeader memory hdr, CometBftLib.SeiCommit memory c) = h.parseSignedHeader(SIGNED_HEADER);

        console2.log("parsed chainId:", hdr.chainId);
        console2.log("parsed height:", uint256(uint64(hdr.height)));
        console2.log("parsed timeSeconds:", uint256(uint64(hdr.timeSeconds)));
        console2.log("parsed timeNanos:", uint256(uint32(hdr.timeNanos)));
        console2.log("parsed validatorsHash:");
        console2.logBytes32(hdr.validatorsHash);
        console2.log("parsed appHash:");
        console2.logBytes32(hdr.appHash);
        console2.log("parsed proposer:");
        console2.logBytes20(hdr.proposerAddress);

        bytes32 hh = h.headerHash(hdr);
        console2.log("computed headerHash:");
        console2.logBytes32(hh);
        console2.log("expected headerHash:");
        console2.logBytes32(EXPECTED_HEADER_HASH);
        console2.log("HEADER HASH MATCH:", hh == EXPECTED_HEADER_HASH);

        console2.log("commit round:", uint256(uint32(c.round)));
        console2.log("commit partSetTotal:", uint256(c.partSetTotal));
        console2.log("commit nSigs:", c.signatures.length);
        console2.log("sig0 tsSec:", uint256(uint64(c.signatures[0].timestampSeconds)));
        console2.log("sig0 tsNanos:", uint256(uint32(c.signatures[0].timestampNanos)));

        bytes memory sb = h.precommitSignBytes(
            hdr.chainId,
            hdr.height,
            c.round,
            hh,
            c.partSetTotal,
            c.partSetHash,
            c.signatures[0].timestampSeconds,
            c.signatures[0].timestampNanos
        );
        console2.log("signBytes len:", sb.length);
        console2.log("signBytes:");
        console2.logBytes(sb);

        bool ok = h.verifyEd(PUBKEY, sb, SIG);
        console2.log("ED25519 VERIFY:", ok);
    }

    /// @dev Real IAVL non-existence proof captured from sei1 for the absent receivedRunningHash
    ///      slot. Confirms the new ICS-23 non-membership path verifies neighbour bracketing.
    function test_realNonExistenceProof() public view {
        (bytes32 leftRoot, bytes32 rightRoot) = h.checkNonMembership(IAVL_PROOF, ABSENT_KEY);
        console2.log("non-existence left root:");
        console2.logBytes32(leftRoot);
        console2.log("non-existence right root:");
        console2.logBytes32(rightRoot);
        assertEq(leftRoot, rightRoot, "left/right neighbour roots must match");
        assertTrue(leftRoot != bytes32(0), "root must be non-zero");
    }
}
