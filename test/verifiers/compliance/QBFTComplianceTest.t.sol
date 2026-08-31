// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {ClprEvmStorageComplianceTest} from "@test/verifiers/compliance/ClprEvmStorageComplianceTest.sol";
import {QbftSyntheticProofs} from "@test/helpers/QbftSyntheticProofs.sol";
import {IClprVerifier} from "@hiero-ledger/clpr/interfaces/IClprVerifier.sol";
import {QBFTVerifier} from "@hiero-ledger/clpr/verifiers/evm/qbft/QBFTVerifier.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";
import {ClprProtobuf} from "@hiero-ledger/clpr/libraries/codec/ClprProtobuf.sol";
import {ClprQbftSeal} from "@hiero-ledger/clpr/libraries/proof/qbft/ClprQbftSeal.sol";
import {ClprEvmStateProof} from "@hiero-ledger/clpr/libraries/proof/evm/ClprEvmStateProof.sol";
import {RLP} from "@openzeppelin/contracts/utils/RLP.sol";

/// @title QBFTComplianceTest
contract QBFTComplianceTest is ClprEvmStorageComplianceTest, QbftSyntheticProofs {
    uint256 internal constant VALIDATOR_PK = uint256(keccak256("qbft-validator"));
    address internal constant SERVICE_ADDR = 0x5e7c1Ce1acCE5E7C1Ce1ACCe5e7c1CE1ACce5e7C;
    bytes32 internal constant SERVICE_CODE_HASH = bytes32(uint256(0xC0DE));
    uint64 internal constant GENESIS_EPOCH_LENGTH = 30000;
    uint64 internal constant GENESIS_EPOCH_NUMBER = 0;
    bytes32 internal constant SYNTHETIC_CHANNEL_ID = bytes32(uint256(0xC0FFEE));

    address internal validatorAddr;

    function _deployVerifier() internal override returns (IClprVerifier) {
        validatorAddr = vm.addr(VALIDATOR_PK);
        return IClprVerifier(deployCode("QBFTVerifier.sol:QBFTVerifier", abi.encode(uint8(1))));
    }

    function _validConfig() internal pure override returns (ConfigVector memory) {
        return ConfigVector({
            configProof: _buildSyntheticConfigProof(
                VALIDATOR_PK, SERVICE_ADDR, SERVICE_CODE_HASH, "eip155:1", GENESIS_EPOCH_LENGTH
            ),
            channelId: SYNTHETIC_CHANNEL_ID,
            expectedChainId: "eip155:1",
            expectedServiceAddress: abi.encodePacked(SERVICE_ADDR)
        });
    }

    function _validBundle() internal view override returns (BundleVector memory) {
        return BundleVector({
            proofBytes: _buildValidBundleProof(),
            trustAnchor: _validTrustAnchor(),
            channelContext: _validChannelContext(),
            expectedNextMessageId: 0,
            expectedPayloadCount: 0
        });
    }

    function _crossChannelVector()
        internal
        view
        override
        returns (bytes memory, bytes memory, bytes memory, bytes memory)
    {
        bytes32 attackerConnId = bytes32(uint256(0xDEADBEEF));
        bytes memory attackerContext = ClprTypes.encodeChannelContext(
            ClprTypes.ChannelContext({channelId: attackerConnId, remoteServiceAddress: abi.encodePacked(SERVICE_ADDR)})
        );
        // The verifier derives attackerConnId's slot +1 and finds it absent from the proof.
        bytes32 expectedMissingSlot = bytes32(uint256(keccak256(abi.encode(attackerConnId, uint256(15)))) + 1);
        return (
            _buildValidBundleProof(),
            _validTrustAnchor(),
            attackerContext,
            abi.encodeWithSelector(ClprEvmStateProof.SlotNotProven.selector, expectedMissingSlot)
        );
    }

    /// @dev QBFT keeps the config-time manifest proof independent of the config proof: its own
    ///      sealed header anchors an account proof for the config's service address, and the
    ///      manifest-commitment slot is proven under that account's storage root.
    ///      Shape: `RLP([sealedHeader, accountProof, manifestStorageProof, manifestPreimage])`.
    function _manifestConfigVector(bytes memory committedPreimage, bytes memory carriedPreimage)
        internal
        pure
        override
        returns (bytes memory configProof, bytes32 channelId, bytes memory manifestProof)
    {
        configProof = _buildSyntheticConfigProof(
            VALIDATOR_PK, SERVICE_ADDR, SERVICE_CODE_HASH, "eip155:1", GENESIS_EPOCH_LENGTH
        );
        channelId = SYNTHETIC_CHANNEL_ID;

        // Prove slot 18 == keccak256(preimage) so the verifier can bind the supplied preimage to the
        // on-ledger commitment.
        bytes32 slot = bytes32(MANIFEST_COMMITMENT_SLOT);
        (bytes32 storageRoot, bytes memory proofNodes) = _buildSyntheticMPTProof(
            keccak256(abi.encodePacked(slot)), RLP.encode(uint256(keccak256(committedPreimage)))
        );

        bytes[] memory entry = new bytes[](2);
        entry[0] = RLP.encode(abi.encodePacked(slot));
        entry[1] = proofNodes;
        bytes[] memory entries = new bytes[](1);
        entries[0] = RLP.encode(entry);

        // codeHash is unpinned at config time (the trust anchor establishes the account), but supply
        // the real one so the fixture stays representative of a live proof.
        (bytes32 stateRoot, bytes memory accountProofRlp) =
            _buildSyntheticAccountProof(SERVICE_ADDR, storageRoot, SERVICE_CODE_HASH);

        bytes[] memory p = new bytes[](4);
        p[0] = _buildSealedCurrentHeader(1, stateRoot, VALIDATOR_PK);
        p[1] = accountProofRlp;
        p[2] = RLP.encode(entries);
        p[3] = RLP.encode(carriedPreimage);
        manifestProof = RLP.encode(p);
    }

    // ── QBFT proof assembly ──────────

    /// @dev A 5-item bundle: current header + no epoch headers (no rotation) + account proof +
    ///      4-slot channel storage proof, all keyed to SYNTHETIC_CHANNEL_ID / SERVICE_ADDR.
    function _buildValidBundleProof() private pure returns (bytes memory) {
        (bytes32 storageRoot, bytes memory storageProofRlp) = _buildChannelStorageProof(SYNTHETIC_CHANNEL_ID);
        (bytes32 stateRoot, bytes memory accountProofRlp) =
            _buildSyntheticAccountProof(SERVICE_ADDR, storageRoot, SERVICE_CODE_HASH);
        bytes memory header = _buildSealedCurrentHeader(1, stateRoot, VALIDATOR_PK);

        bytes[] memory top = new bytes[](5);
        top[0] = header;
        top[1] = hex"c0"; // empty epoch headers — no rotation
        top[2] = accountProofRlp;
        top[3] = storageProofRlp;
        top[4] = RLP.encode(new bytes(0));
        return RLP.encode(top);
    }

    function _validTrustAnchor() private view returns (bytes memory) {
        return abi.encode(validatorAddr, SERVICE_CODE_HASH, GENESIS_EPOCH_LENGTH, GENESIS_EPOCH_NUMBER);
    }

    function _validChannelContext() private pure returns (bytes memory) {
        return ClprTypes.encodeChannelContext(
            ClprTypes.ChannelContext({
                channelId: SYNTHETIC_CHANNEL_ID, remoteServiceAddress: abi.encodePacked(SERVICE_ADDR)
            })
        );
    }

    // ── Hook implementations ─────────────────────────────────────────────────

    function _runningHashVector() internal view override returns (RunningHashVector memory) {
        bytes memory payload = ClprProtobuf.encodeDataMessage(hex"01", hex"02", hex"03", hex"04");
        bytes32 expectedSentRunningHash = sha256(abi.encodePacked(bytes32(0), sha256(payload)));

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;
        ClprTypes.QueueMetadata memory dummyMeta;
        bytes memory bundleContent = ClprProtobuf.encodeBundleContent(dummyMeta, payloads);

        return RunningHashVector({
            proofBytes: _buildBundleProofWithSentHash(expectedSentRunningHash, bundleContent),
            trustAnchor: _validTrustAnchor(),
            channelContext: _validChannelContext(),
            previousRunningHash: bytes32(0)
        });
    }

    /// @dev For QBFT the network identity is the validator that signed the config header.
    ///      Claiming a different validator address in proof[0] than the actual seal signer is
    ///      the QBFT realization of "proof from a different chain."
    function _wrongChainConfigVector() internal pure override returns (bytes memory, bytes32) {
        address wrongClaim = address(uint160(uint256(keccak256("different-network-validator"))));

        bytes memory header = _buildSealedCurrentHeader(0, bytes32(0), VALIDATOR_PK);

        bytes[] memory throttleItems = new bytes[](5);
        for (uint256 i = 0; i < 5; i++) {
            throttleItems[i] = RLP.encode(uint256(0));
        }

        bytes[] memory taItems = new bytes[](3);
        taItems[0] = RLP.encode(vm.addr(VALIDATOR_PK));
        taItems[1] = RLP.encode(abi.encodePacked(SERVICE_ADDR));
        taItems[2] = RLP.encode(SERVICE_CODE_HASH);

        bytes[] memory items = new bytes[](10);
        items[0] = RLP.encode(wrongClaim); // claimed identity mismatches actual seal signer
        items[1] = RLP.encode(abi.encodePacked(SERVICE_ADDR));
        items[2] = RLP.encode(new bytes(0));
        items[3] = RLP.encode(bytes("eip155:999"));
        items[4] = RLP.encode(uint256(0));
        items[5] = RLP.encode(throttleItems);
        items[6] = RLP.encode(RLP.encode(taItems));
        items[7] = RLP.encode(new bytes(0));
        items[8] = header;
        items[9] = RLP.encode(uint256(GENESIS_EPOCH_LENGTH));

        return (RLP.encode(items), SYNTHETIC_CHANNEL_ID);
    }

    /// @dev QBFT verifyConfig requires exactly 10 RLP items; a 9-item proof (epochLength absent)
    ///      is the QBFT realization of "partial field coverage."
    function _partialSlotCoverageVector() internal pure override returns (bytes memory, bytes32) {
        bytes memory header = _buildSealedCurrentHeader(0, bytes32(0), VALIDATOR_PK);

        bytes[] memory throttleItems = new bytes[](5);
        for (uint256 i = 0; i < 5; i++) {
            throttleItems[i] = RLP.encode(uint256(0));
        }

        bytes[] memory taItems = new bytes[](3);
        taItems[0] = RLP.encode(vm.addr(VALIDATOR_PK));
        taItems[1] = RLP.encode(abi.encodePacked(SERVICE_ADDR));
        taItems[2] = RLP.encode(SERVICE_CODE_HASH);

        bytes[] memory items = new bytes[](9); // omits items[9] (epochLength)
        items[0] = RLP.encode(vm.addr(VALIDATOR_PK));
        items[1] = RLP.encode(abi.encodePacked(SERVICE_ADDR));
        items[2] = RLP.encode(new bytes(0));
        items[3] = RLP.encode(bytes("eip155:1"));
        items[4] = RLP.encode(uint256(0));
        items[5] = RLP.encode(throttleItems);
        items[6] = RLP.encode(RLP.encode(taItems));
        items[7] = RLP.encode(new bytes(0));
        items[8] = header;

        return (RLP.encode(items), SYNTHETIC_CHANNEL_ID);
    }

    function _wrongServiceAddressVector() internal view override returns (bytes memory, bytes memory, bytes memory) {
        address differentService = address(uint160(uint256(keccak256("different-service"))));
        bytes memory wrongContext = ClprTypes.encodeChannelContext(
            ClprTypes.ChannelContext({
                channelId: SYNTHETIC_CHANNEL_ID, remoteServiceAddress: abi.encodePacked(differentService)
            })
        );
        return (_buildValidBundleProof(), _validTrustAnchor(), wrongContext);
    }

    /// @dev 3-entry storage proof: offsets [+1, +2, +4] — the remaining required slots absent.
    ///      The verifier requires exactly 5 or 6 entries; 3 triggers InvalidStorageProofShape.
    function _threeSlotStorageVector() internal view override returns (bytes memory, bytes memory, bytes memory) {
        bytes32 cBase = keccak256(abi.encode(SYNTHETIC_CHANNEL_ID, uint256(15)));
        (bytes32 storageRoot, bytes memory proofNodesRlp) =
            _buildSyntheticMPTProof(keccak256(abi.encodePacked(bytes32(uint256(cBase) + 1))), RLP.encode(uint256(0)));

        uint8[3] memory offsets = [1, 2, 4];
        bytes[] memory entries = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            bytes32 slotKey = bytes32(uint256(cBase) + offsets[i]);
            bytes[] memory entry = new bytes[](2);
            entry[0] = RLP.encode(abi.encodePacked(slotKey));
            entry[1] = proofNodesRlp;
            entries[i] = RLP.encode(entry);
        }

        (bytes32 stateRoot, bytes memory accountProofRlp) =
            _buildSyntheticAccountProof(SERVICE_ADDR, storageRoot, SERVICE_CODE_HASH);
        bytes memory header = _buildSealedCurrentHeader(1, stateRoot, VALIDATOR_PK);

        bytes[] memory top = new bytes[](5);
        top[0] = header;
        top[1] = hex"c0";
        top[2] = accountProofRlp;
        top[3] = RLP.encode(entries);
        top[4] = RLP.encode(new bytes(0));
        return (RLP.encode(top), _validTrustAnchor(), _validChannelContext());
    }

    /// @dev 5-entry storage proof with offsets [+1, +2, +3, +5, +16] — uses cBase+3 instead of
    ///      cBase+4 (sentRunningHash slot). The verifier derives cBase+4 from the layout and cannot
    ///      find it in the proof, so it reverts with SlotNotProven(cBase+4).
    function _wrongSlotIndexVector() internal view override returns (bytes memory, bytes memory, bytes memory) {
        bytes32 cBase = keccak256(abi.encode(SYNTHETIC_CHANNEL_ID, uint256(15)));
        (bytes32 storageRoot, bytes memory proofNodesRlp) =
            _buildSyntheticMPTProof(keccak256(abi.encodePacked(bytes32(uint256(cBase) + 1))), RLP.encode(uint256(0)));

        uint8[5] memory offsets = [1, 2, 3, 5, 16]; // +3 in place of +4
        bytes[] memory entries = new bytes[](5);
        for (uint256 i = 0; i < 5; i++) {
            bytes32 slotKey = bytes32(uint256(cBase) + offsets[i]);
            bytes[] memory entry = new bytes[](2);
            entry[0] = RLP.encode(abi.encodePacked(slotKey));
            entry[1] = proofNodesRlp;
            entries[i] = RLP.encode(entry);
        }

        (bytes32 stateRoot, bytes memory accountProofRlp) =
            _buildSyntheticAccountProof(SERVICE_ADDR, storageRoot, SERVICE_CODE_HASH);
        bytes memory header = _buildSealedCurrentHeader(1, stateRoot, VALIDATOR_PK);

        bytes[] memory top = new bytes[](5);
        top[0] = header;
        top[1] = hex"c0";
        top[2] = accountProofRlp;
        top[3] = RLP.encode(entries);
        top[4] = RLP.encode(new bytes(0));
        return (RLP.encode(top), _validTrustAnchor(), _validChannelContext());
    }

    // ── Private helpers ──────────────────────────────────────────────────────

    /// @dev Build a QBFT bundle proof where the message running-hash slot (bundle-scoped:
    ///      messageId = ackedMessageId(0) + payloadCount(1) = 1) proves sentHash; the five
    ///      channel slots are absent from the trie (value = 0). The bundle-scoped verifier
    ///      overrides metadata.sentRunningHash with the proven message running hash.
    function _buildBundleProofWithSentHash(bytes32 sentHash, bytes memory bundleContent)
        private
        pure
        returns (bytes memory)
    {
        bytes32 cBase = keccak256(abi.encode(SYNTHETIC_CHANNEL_ID, uint256(15)));
        // The synthetic trie holds ONE leaf, so exactly one proven slot can carry a chosen value.
        // Key it at Channel slot +4 (`sentRunningHash`) — the field this vector asserts on. Since
        // #379 reverted bundle-scoped metadata, `sentRunningHash` is taken straight from that proven
        // slot rather than being overridden from the last-message running-hash entry.
        (bytes32 storageRoot, bytes memory proofNodes) = _buildSyntheticMPTProof(
            keccak256(abi.encodePacked(bytes32(uint256(cBase) + 4))), RLP.encode(uint256(sentHash))
        );

        // Five entries (ACK-only shape): the optional sixth last-message running-hash entry is what
        // triggers the `nextMessageId != 0` guard, and it is not needed here — the message payloads
        // this vector chains over come from the bundle content (RLP item 4), not from the storage
        // proof, and post-#379 nothing ties the payload count to the entry count.
        uint8[5] memory offsets = [1, 2, 4, 5, 16];
        bytes[] memory storageEntries = new bytes[](5);
        for (uint256 i = 0; i < 5; i++) {
            bytes32 slotKey = bytes32(uint256(cBase) + offsets[i]);
            bytes[] memory entry = new bytes[](2);
            entry[0] = RLP.encode(abi.encodePacked(slotKey));
            entry[1] = proofNodes;
            storageEntries[i] = RLP.encode(entry);
        }

        (bytes32 stateRoot, bytes memory accountProofRlp) =
            _buildSyntheticAccountProof(SERVICE_ADDR, storageRoot, SERVICE_CODE_HASH);
        bytes memory header = _buildSealedCurrentHeader(1, stateRoot, VALIDATOR_PK);

        bytes[] memory top = new bytes[](5);
        top[0] = header;
        top[1] = hex"c0";
        top[2] = accountProofRlp;
        top[3] = RLP.encode(storageEntries);
        top[4] = RLP.encode(bundleContent);
        return RLP.encode(top);
    }
}
