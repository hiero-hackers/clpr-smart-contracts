// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ClprEvmStateProof} from "@hiero-ledger/clpr/libraries/proof/evm/ClprEvmStateProof.sol";
import {RLP} from "@openzeppelin/contracts/utils/RLP.sol";
import {Memory} from "@openzeppelin/contracts/utils/Memory.sol";

contract ClprEvmStateProofHarness {
    function decodeAccount(bytes memory accountRlp) external pure returns (bytes32 storageRoot, bytes32 codeHash) {
        return ClprEvmStateProof.decodeAccount(accountRlp);
    }

    /// @dev Accepts an RLP-encoded outer list of entries (each a 2-item list [slot, proofList]).
    function verifyProvenSlots(bytes memory entriesEncoded, bytes32 storageRoot, bytes32[] memory expectedSlots)
        external
        pure
        returns (bytes32[] memory)
    {
        Memory.Slice[] memory entries = RLP.decodeList(entriesEncoded);
        return ClprEvmStateProof.verifyProvenSlots(entries, storageRoot, expectedSlots);
    }
}

contract ClprEvmStateProofTest is Test {
    ClprEvmStateProofHarness internal h;

    function setUp() public {
        h = new ClprEvmStateProofHarness();
    }

    // ── decodeAccount ─────────────────────────────────────────────────────────

    function test_decodeAccount_reverts_wrongFieldCount() public {
        // 3-item list instead of expected 4-item account RLP.
        bytes[] memory items = new bytes[](3);
        items[0] = RLP.encode(uint256(0)); // nonce
        items[1] = RLP.encode(uint256(0)); // balance
        items[2] = RLP.encode(bytes32(0)); // storageRoot only (missing codeHash)
        bytes memory badAccount = RLP.encode(items);
        vm.expectRevert(ClprEvmStateProof.InvalidAccount.selector);
        h.decodeAccount(badAccount);
    }

    function test_decodeAccount_success() public view {
        bytes32 expectedStorage = bytes32(uint256(0xdeadbeef));
        bytes32 expectedCode = bytes32(uint256(0xcafebabe));
        bytes[] memory items = new bytes[](4);
        items[0] = RLP.encode(uint256(1)); // nonce
        items[1] = RLP.encode(uint256(0)); // balance
        items[2] = RLP.encode(expectedStorage); // storageRoot
        items[3] = RLP.encode(expectedCode); // codeHash
        bytes memory accountRlp = RLP.encode(items);
        (bytes32 storageRoot, bytes32 codeHash) = h.decodeAccount(accountRlp);
        assertEq(storageRoot, expectedStorage);
        assertEq(codeHash, expectedCode);
    }

    // ── verifyProvenSlots ─────────────────────────────────────────────────────

    function test_verifyProvenSlots_invalidEntry_reverts() public {
        // Build a 3-item entry instead of the required 2-item [slot, proofList].
        bytes[] memory entryItems = new bytes[](3);
        entryItems[0] = RLP.encode(bytes32(uint256(0x01)));
        entryItems[1] = RLP.encode(new bytes(0));
        entryItems[2] = RLP.encode(new bytes(0));
        bytes memory badEntry = RLP.encode(entryItems);
        bytes memory outerList = RLP.encode(_singleton(badEntry));

        bytes32[] memory slots = new bytes32[](1);
        slots[0] = bytes32(uint256(0x01));

        vm.expectRevert(ClprEvmStateProof.InvalidStorageEntry.selector);
        h.verifyProvenSlots(outerList, bytes32(0), slots);
    }

    function test_verifyProvenSlots_slotNotFound_reverts() public {
        bytes32 slot = bytes32(uint256(0x01));
        bytes32 otherSlot = bytes32(uint256(0x02));
        bytes memory entry = _buildAbsentSlotEntry(otherSlot, slot); // entry is for otherSlot, not slot
        bytes memory outerList = RLP.encode(_singleton(entry));

        bytes32[] memory slots = new bytes32[](1);
        slots[0] = slot;

        vm.expectRevert(abi.encodeWithSelector(ClprEvmStateProof.SlotNotProven.selector, slot));
        h.verifyProvenSlots(outerList, keccak256("storageRoot"), slots);
    }

    function test_verifyProvenSlots_found_absentValue_returnsZero() public view {
        bytes32 slot = bytes32(uint256(0x42));
        bytes32 keyHash = keccak256(abi.encodePacked(slot));
        (bytes32 storageRoot, bytes memory proofListRlp) = _buildAbsentProof(keyHash);
        bytes memory entry = _buildEntry(slot, proofListRlp);
        bytes memory outerList = RLP.encode(_singleton(entry));

        bytes32[] memory slots = new bytes32[](1);
        slots[0] = slot;

        bytes32[] memory values = h.verifyProvenSlots(outerList, storageRoot, slots);
        assertEq(values.length, 1);
        assertEq(values[0], bytes32(0));
    }

    function test_verifyProvenSlots_found_emptyLeaf_returnsZero() public view {
        // Leaf with empty value (0x80 = RLP of empty bytes) hits _decodeStorageScalar's
        // inner.length == 0 branch (line 77 in ClprEvmStateProof.sol).
        bytes32 slot = bytes32(uint256(0x99));
        bytes32 keyHash = keccak256(abi.encodePacked(slot));
        (bytes32 storageRoot, bytes memory proofListRlp) = _buildEmptyValueLeafProof(keyHash);
        bytes memory entry = _buildEntry(slot, proofListRlp);
        bytes memory outerList = RLP.encode(_singleton(entry));

        bytes32[] memory slots = new bytes32[](1);
        slots[0] = slot;

        bytes32[] memory values = h.verifyProvenSlots(outerList, storageRoot, slots);
        assertEq(values[0], bytes32(0));
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    /// @dev Build a single-element bytes[] for RLP.encode(bytes[]).
    function _singleton(bytes memory item) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](1);
        arr[0] = item;
    }

    /// @dev Build an entry [slotBytes32, proofListRlp] for verifyProvenSlots.
    function _buildEntry(bytes32 slot, bytes memory proofListRlp) internal pure returns (bytes memory) {
        bytes[] memory items = new bytes[](2);
        items[0] = RLP.encode(slot);
        items[1] = proofListRlp;
        return RLP.encode(items);
    }

    /// @dev Build an entry for `otherSlot` that will be skipped when looking for `targetSlot`.
    function _buildAbsentSlotEntry(
        bytes32 otherSlot,
        bytes32 /*targetSlot*/
    )
        internal
        pure
        returns (bytes memory)
    {
        // proof doesn't matter — we just need the slot number to not match targetSlot
        bytes32 keyHash = keccak256(abi.encodePacked(otherSlot));
        (, bytes memory proofListRlp) = _buildAbsentProof(keyHash);
        return _buildEntry(otherSlot, proofListRlp);
    }

    /// @dev Build a branch-all-empty proof (key absent) for the given keyHash.
    ///      Returns (storageRoot, proofListRlp) where proofListRlp is an RLP list of [RLP(branchNode)].
    function _buildAbsentProof(
        bytes32 /*keyHash*/
    )
        internal
        pure
        returns (bytes32 storageRoot, bytes memory proofListRlp)
    {
        bytes[] memory branchItems = new bytes[](17);
        for (uint256 i = 0; i < 17; i++) {
            branchItems[i] = RLP.encode(new bytes(0));
        }
        bytes memory branchNode = RLP.encode(branchItems);
        storageRoot = keccak256(branchNode);
        bytes[] memory proofList = new bytes[](1);
        proofList[0] = RLP.encode(branchNode); // wrapped as byte string
        proofListRlp = RLP.encode(proofList);
    }

    /// @dev Build a leaf proof where the leaf value = 0x80 (RLP of empty bytes).
    ///      getOrEmpty returns 0x80 → _decodeStorageScalar sees inner.length == 0.
    function _buildEmptyValueLeafProof(bytes32 keyHash)
        internal
        pure
        returns (bytes32 storageRoot, bytes memory proofListRlp)
    {
        bytes memory leafPath = new bytes(33);
        leafPath[0] = 0x20; // leaf, even
        for (uint256 i = 0; i < 32; i++) {
            leafPath[i + 1] = keyHash[i];
        }
        bytes[] memory leafItems = new bytes[](2);
        leafItems[0] = RLP.encode(leafPath);
        leafItems[1] = RLP.encode(new bytes(0)); // empty value → 0x80 in the leaf
        bytes memory leafNode = RLP.encode(leafItems);
        storageRoot = keccak256(leafNode);
        bytes[] memory proofList = new bytes[](1);
        proofList[0] = RLP.encode(leafNode); // wrapped as byte string
        proofListRlp = RLP.encode(proofList);
    }
}
