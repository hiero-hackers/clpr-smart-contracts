// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MerklePatriciaProof} from "@hiero-ledger/clpr/libraries/proof/evm/MerklePatriciaProof.sol";
import {RLP} from "@openzeppelin/contracts/utils/RLP.sol";

contract MPTHarness {
    function verifyInclusion(bytes32 root, bytes32 keyHash, bytes[] memory proof) external pure returns (bytes memory) {
        return MerklePatriciaProof.verifyInclusion(root, keyHash, proof);
    }

    function getOrEmpty(bytes32 root, bytes32 keyHash, bytes[] memory proof) external pure returns (bytes memory) {
        return MerklePatriciaProof.getOrEmpty(root, keyHash, proof);
    }
}

contract MerklePatriciaProofTest is Test {
    MPTHarness internal h;

    // keyHash with nibble0=0, nibble63=1 (bytes32(uint256(1)))
    bytes32 internal constant KEY_HASH_1 = bytes32(uint256(1));
    // keyHash all zeros
    bytes32 internal constant KEY_HASH_0 = bytes32(0);

    function setUp() public {
        h = new MPTHarness();
    }

    // ── verifyInclusion ────────────────────────────────────────────────────────

    function test_verifyInclusion_emptyProof_reverts() public {
        bytes[] memory proof = new bytes[](0);
        vm.expectRevert(MerklePatriciaProof.MPTEmptyProof.selector);
        h.verifyInclusion(bytes32(0), KEY_HASH_0, proof);
    }

    function test_verifyInclusion_hashMismatch_reverts() public {
        (bytes32 root, bytes[] memory proof) = _leafProof(KEY_HASH_0, hex"cafe");
        vm.expectRevert(MerklePatriciaProof.MPTInvalidHashRef.selector);
        h.verifyInclusion(bytes32(uint256(root) ^ 1), KEY_HASH_0, proof); // wrong root
    }

    function test_verifyInclusion_singleLeaf_returnsValue() public view {
        bytes memory value = hex"deadbeef";
        (bytes32 root, bytes[] memory proof) = _leafProof(KEY_HASH_0, value);
        bytes memory got = h.verifyInclusion(root, KEY_HASH_0, proof);
        assertEq(got, RLP.encode(value)); // verifyInclusion returns the RLP-encoded leaf item
    }

    function test_verifyInclusion_branchThenLeaf_returnsValue() public view {
        bytes memory value = hex"aabb";
        (bytes32 root, bytes[] memory proof) = _branchThenLeafProof(KEY_HASH_1, value);
        bytes memory got = h.verifyInclusion(root, KEY_HASH_1, proof);
        assertEq(got, RLP.encode(value));
    }

    function test_verifyInclusion_branchTerminal_returnsValue() public view {
        bytes memory value = hex"1234";
        (bytes32 root, bytes[] memory proof) = _branchTerminalProof(KEY_HASH_1, value);
        bytes memory got = h.verifyInclusion(root, KEY_HASH_1, proof);
        assertEq(got, RLP.encode(value));
    }

    function test_verifyInclusion_extensionThenLeaf_returnsValue() public view {
        bytes memory value = hex"ff00";
        (bytes32 root, bytes[] memory proof) = _extensionThenLeafProof(KEY_HASH_0, value);
        bytes memory got = h.verifyInclusion(root, KEY_HASH_0, proof);
        assertEq(got, RLP.encode(value));
    }

    function test_verifyInclusion_keyAbsent_reverts() public {
        bytes32 root;
        bytes[] memory proof;
        (root, proof) = _branchAbsentProof(KEY_HASH_1);
        vm.expectRevert(MerklePatriciaProof.MPTKeyAbsent.selector);
        h.verifyInclusion(root, KEY_HASH_1, proof);
    }

    function test_verifyInclusion_pathLengthOverflow_reverts() public {
        // Build a leaf whose path encodes 65 nibbles — too long for the 64-nibble key space.
        bytes memory overPath = new bytes(33); // 33 bytes × 2 nibbles - 1 (odd) = 65 nibbles
        overPath[0] = 0x30; // leaf, odd
        bytes[] memory leafItems = new bytes[](2);
        leafItems[0] = RLP.encode(overPath);
        leafItems[1] = RLP.encode(bytes(hex"aa"));
        bytes memory leafNode = RLP.encode(leafItems);
        bytes32 root = keccak256(leafNode);
        bytes[] memory proof = new bytes[](1);
        proof[0] = leafNode;
        vm.expectRevert(MerklePatriciaProof.MPTKeyMismatch.selector);
        h.verifyInclusion(root, KEY_HASH_0, proof);
    }

    function test_verifyInclusion_nibbleMismatch_reverts() public {
        // Build proof for KEY_HASH_0; look up with a different key — nibble 63 diverges.
        (bytes32 root, bytes[] memory proof) = _leafProof(KEY_HASH_0, hex"cafe");
        vm.expectRevert(MerklePatriciaProof.MPTKeyMismatch.selector);
        h.verifyInclusion(root, KEY_HASH_1, proof); // different key
    }

    function test_verifyInclusion_invalidNode_reverts() public {
        // Build a 3-item RLP list — not a valid MPT node.
        bytes[] memory items = new bytes[](3);
        items[0] = RLP.encode(bytes(hex"aa"));
        items[1] = RLP.encode(bytes(hex"bb"));
        items[2] = RLP.encode(bytes(hex"cc"));
        bytes memory badNode = RLP.encode(items);
        bytes32 root = keccak256(badNode);
        bytes[] memory proof = new bytes[](1);
        proof[0] = badNode;
        vm.expectRevert(MerklePatriciaProof.MPTInvalidNode.selector);
        h.verifyInclusion(root, KEY_HASH_0, proof);
    }

    function test_verifyInclusion_proofEndedEarly_reverts() public {
        // Extension node alone — the leaf that should follow is absent.
        (bytes32 root, bytes[] memory extOnly) = _extensionNodeOnly(KEY_HASH_0);
        vm.expectRevert(MerklePatriciaProof.MPTProofEndedEarly.selector);
        h.verifyInclusion(root, KEY_HASH_0, extOnly);
    }

    function test_verifyInclusion_invalidPathPrefix_prefixNibTooHigh_reverts() public {
        bytes memory badPath = new bytes(33);
        badPath[0] = 0x40; // prefixNib = 4 > 3 — invalid
        bytes[] memory leafItems = new bytes[](2);
        leafItems[0] = RLP.encode(badPath);
        leafItems[1] = RLP.encode(bytes(hex"aa"));
        bytes memory node = RLP.encode(leafItems);
        bytes32 root = keccak256(node);
        bytes[] memory proof = new bytes[](1);
        proof[0] = node;
        vm.expectRevert(MerklePatriciaProof.MPTInvalidPathPrefix.selector);
        h.verifyInclusion(root, KEY_HASH_0, proof);
    }

    function test_verifyInclusion_invalidPathPrefix_evenWithLowNibble_reverts() public {
        bytes memory badPath = new bytes(33);
        badPath[0] = 0x01; // prefixNib = 0 (even), but low nibble = 1 (must be 0 for even)
        bytes[] memory leafItems = new bytes[](2);
        leafItems[0] = RLP.encode(badPath);
        leafItems[1] = RLP.encode(bytes(hex"aa"));
        bytes memory node = RLP.encode(leafItems);
        bytes32 root = keccak256(node);
        bytes[] memory proof = new bytes[](1);
        proof[0] = node;
        vm.expectRevert(MerklePatriciaProof.MPTInvalidPathPrefix.selector);
        h.verifyInclusion(root, KEY_HASH_0, proof);
    }

    // ── getOrEmpty ─────────────────────────────────────────────────────────────

    function test_getOrEmpty_emptyProof_reverts() public {
        bytes[] memory proof = new bytes[](0);
        vm.expectRevert(MerklePatriciaProof.MPTEmptyProof.selector);
        h.getOrEmpty(bytes32(0), KEY_HASH_0, proof);
    }

    function test_getOrEmpty_leafSuccess_returnsValue() public view {
        bytes memory value = hex"beefcafe";
        (bytes32 root, bytes[] memory proof) = _leafProof(KEY_HASH_0, value);
        bytes memory got = h.getOrEmpty(root, KEY_HASH_0, proof);
        assertEq(got, RLP.encode(value)); // getOrEmpty returns the RLP-encoded leaf item
    }

    function test_getOrEmpty_branchAbsent_returnsEmpty() public view {
        (bytes32 root, bytes[] memory proof) = _branchAbsentProof(KEY_HASH_1);
        bytes memory got = h.getOrEmpty(root, KEY_HASH_1, proof);
        assertEq(got.length, 0);
    }

    function test_getOrEmpty_pathMismatch_returnsEmpty() public view {
        // Proof built for KEY_HASH_0; look up with KEY_HASH_1 → nibble 63 diverges → empty.
        (bytes32 root, bytes[] memory proof) = _leafProof(KEY_HASH_0, hex"cafe");
        bytes memory got = h.getOrEmpty(root, KEY_HASH_1, proof);
        assertEq(got.length, 0);
    }

    function test_getOrEmpty_pathLengthOverflow_returnsEmpty() public view {
        // Build a branch pointing to a leaf whose path is 64 nibbles but keyIdx is already 1.
        bytes memory value = hex"ff";
        bytes memory leafPath = new bytes(33);
        // Even leaf (prefix=2): 33 bytes → totalNibbles=66, pathLen=64.
        // After branch consumed nibble0, keyIdx=1; pathLen+keyIdx = 65 > 64 → return empty.
        leafPath[0] = 0x20;
        for (uint256 i = 1; i < 33; i++) {
            leafPath[i] = KEY_HASH_1[i - 1];
        }
        bytes[] memory leafItems = new bytes[](2);
        leafItems[0] = RLP.encode(leafPath);
        leafItems[1] = RLP.encode(value);
        bytes memory leafNode = RLP.encode(leafItems);
        bytes32 leafHash = keccak256(leafNode);

        uint8 nibble0 = uint8(uint256(KEY_HASH_1) >> 252); // first nibble = 0 for KEY_HASH_1
        bytes[] memory branchItems = new bytes[](17);
        for (uint256 i = 0; i < 16; i++) {
            branchItems[i] = i == nibble0 ? RLP.encode(abi.encodePacked(leafHash)) : RLP.encode(new bytes(0));
        }
        branchItems[16] = RLP.encode(new bytes(0));
        bytes memory branchNode = RLP.encode(branchItems);
        bytes32 root = keccak256(branchNode);

        bytes[] memory proof = new bytes[](2);
        proof[0] = branchNode;
        proof[1] = leafNode;

        bytes memory got = h.getOrEmpty(root, KEY_HASH_1, proof);
        assertEq(got.length, 0);
    }

    function test_getOrEmpty_incompleteKey_returnsEmpty() public view {
        // Leaf covers only 32 nibbles; after traversal keyIdx=32 ≠ 64 → return empty.
        // Use even-prefix path of 32 nibbles.
        bytes memory leafPath = new bytes(17); // 17 bytes → totalNibbles=34 → pathLen=32
        leafPath[0] = 0x20; // leaf, even
        // nibbles 0..31 all zero → matches KEY_HASH_0
        bytes[] memory leafItems = new bytes[](2);
        leafItems[0] = RLP.encode(leafPath);
        leafItems[1] = RLP.encode(bytes(hex"1234"));
        bytes memory leafNode = RLP.encode(leafItems);
        bytes32 root = keccak256(leafNode);
        bytes[] memory proof = new bytes[](1);
        proof[0] = leafNode;
        bytes memory got = h.getOrEmpty(root, KEY_HASH_0, proof);
        assertEq(got.length, 0);
    }

    // ── Empty-path leaf node ────────────────────────────────────────────────

    function test_verifyInclusion_emptyPathLeaf_reverts() public {
        // Build a leaf whose path item is RLP-encoded as an empty byte string.
        // When verifyInclusion traverses this leaf, _decodePathPrefix reverts on
        // the zero-length path (line 172).
        bytes[] memory leafItems = new bytes[](2);
        leafItems[0] = RLP.encode(new bytes(0)); // RLP zero-length → decodes as bytes(0)
        leafItems[1] = RLP.encode(bytes(hex"aa"));
        bytes memory leafNode = RLP.encode(leafItems);
        bytes32 root = keccak256(leafNode);
        bytes[] memory proof = new bytes[](1);
        proof[0] = leafNode;
        vm.expectRevert(MerklePatriciaProof.MPTInvalidPathPrefix.selector);
        h.verifyInclusion(root, KEY_HASH_0, proof);
    }

    function test_getOrEmpty_branchPointsToEmptyChild_returnsEmpty() public view {
        // Branch with all slots encoding empty byte strings. For KEY_HASH_0 nibble0=0,
        // items[0] decodes to bytes(0) → child.length == 0 triggers line 111 in getOrEmpty.
        bytes[] memory branchItems = new bytes[](17);
        for (uint256 i = 0; i < 17; i++) {
            branchItems[i] = RLP.encode(new bytes(0)); // empty byte string at every slot
        }
        bytes memory branchNode = RLP.encode(branchItems);
        bytes32 root = keccak256(branchNode);

        // KEY_HASH_0 nibble0=0 → items[0] = bytes(0) → child.length==0 → line 111
        bytes[] memory proof = new bytes[](1);
        proof[0] = branchNode;
        bytes memory got = h.getOrEmpty(root, KEY_HASH_0, proof);
        assertEq(got.length, 0);
    }

    function test_verifyInclusion_oddLeafPath_returnsValue() public view {
        // Branch→odd-leaf where the odd path exactly covers 63 nibbles (2*32-1).
        // After branch consumes nibble 0 of KEY_HASH_0, leaf covers nibbles 1..63.
        // leafPath[0] = 0x30 (leaf + odd, padding nibble = 0) → matches KEY_HASH_0 nibble 1
        // leafPath[1..31] = KEY_HASH_0[1..31] → all zeros match keyHash nibbles 2..63
        bytes memory oddLeafPath = new bytes(32);
        oddLeafPath[0] = 0x30;
        for (uint256 i = 1; i < 32; i++) {
            oddLeafPath[i] = KEY_HASH_0[i]; // all zeros
        }

        bytes[] memory leafItems = new bytes[](2);
        leafItems[0] = RLP.encode(oddLeafPath);
        leafItems[1] = RLP.encode(bytes(hex"deadbeef"));
        bytes memory oddLeafNode = RLP.encode(leafItems);
        bytes32 oddLeafHash = keccak256(oddLeafNode);

        uint8 nib0Key = _nibAt(KEY_HASH_0, 0); // = 0
        bytes[] memory branchItems = new bytes[](17);
        for (uint256 i = 0; i < 16; i++) {
            branchItems[i] = RLP.encode(i == nib0Key ? abi.encodePacked(oddLeafHash) : new bytes(0));
        }
        branchItems[16] = RLP.encode(new bytes(0));
        bytes memory branchNode = RLP.encode(branchItems);
        bytes32 root = keccak256(branchNode);

        // _decodePathPrefix: isOdd=true at line 180 (prefixNib=3), pathLen=63.
        // keyIdx = 1 + 63 = 64 == 64 ✓ → returns leaf value.
        bytes[] memory proof = new bytes[](2);
        proof[0] = branchNode;
        proof[1] = oddLeafNode;

        bytes memory got = h.verifyInclusion(root, KEY_HASH_0, proof);
        assertEq(got, RLP.encode(bytes(hex"deadbeef")));
    }

    // ── BRDA:105 — branch-node terminal at keyIdx==64 ────────────────────────

    /// @dev BRDA:105,15,0,- — `if (keyIdx >= 64) return Memory.toBytes(items[16])`
    ///
    ///      A value can be stored directly in the "value" slot (item[16]) of a branch node
    ///      when the full 64-nibble key has been consumed by the time that node is reached.
    ///      Here a 64-nibble even extension exhausts the key, so the next node is the
    ///      branch and keyIdx==64 on arrival.
    function test_verifyInclusion_branchNodeAtKeyDepth64_returnsSlot16() public view {
        bytes memory value = hex"c0ffee";

        // Branch node: value in slot 16, all other slots empty.
        bytes[] memory branchItems = new bytes[](17);
        for (uint256 i = 0; i < 16; i++) {
            branchItems[i] = RLP.encode(new bytes(0));
        }
        branchItems[16] = RLP.encode(value);
        bytes memory branchNode = RLP.encode(branchItems);
        bytes32 branchHash = keccak256(branchNode);

        // Extension: 64 even nibbles (path = 33 bytes, prefix 0x00, rest zeros).
        // All nibbles are 0 → matches KEY_HASH_0 (all zeros). After traversal keyIdx = 64.
        bytes memory extPath = new bytes(33);
        extPath[0] = 0x00; // ext, even; low nibble MUST be 0x0
        bytes[] memory extItems = new bytes[](2);
        extItems[0] = RLP.encode(extPath);
        extItems[1] = RLP.encode(abi.encodePacked(branchHash));
        bytes memory extNode = RLP.encode(extItems);

        bytes[] memory proof = new bytes[](2);
        proof[0] = extNode;
        proof[1] = branchNode;

        bytes memory got = h.verifyInclusion(keccak256(extNode), KEY_HASH_0, proof);
        assertEq(got, RLP.encode(value));
    }

    // ── proof-building helpers ─────────────────────────────────────────────────

    /// @dev Single-leaf proof for `keyHash` with even 64-nibble path.
    function _leafProof(bytes32 keyHash, bytes memory value)
        internal
        pure
        returns (bytes32 root, bytes[] memory proof)
    {
        bytes memory path = new bytes(33);
        path[0] = 0x20; // leaf, even
        for (uint256 i = 0; i < 32; i++) {
            path[i + 1] = keyHash[i];
        }
        bytes[] memory leafItems = new bytes[](2);
        leafItems[0] = RLP.encode(path);
        leafItems[1] = RLP.encode(value);
        bytes memory leafNode = RLP.encode(leafItems);
        root = keccak256(leafNode);
        proof = new bytes[](1);
        proof[0] = leafNode;
    }

    /// @dev Branch node (17-item) routing on nibble 0, followed by a 63-nibble leaf.
    ///      Works for any keyHash; for KEY_HASH_1 nibble0=0, nibble63=1.
    function _branchThenLeafProof(bytes32 keyHash, bytes memory value)
        internal
        pure
        returns (bytes32 root, bytes[] memory proof)
    {
        // Leaf covers nibbles 1..63 (63 nibbles, odd).
        bytes memory leafPath = new bytes(32);
        uint8 nib0 = _nibAt(keyHash, 0);
        // path[0]: prefix nibble=3 (leaf, odd) in high nibble, nibble-1 in low nibble.
        leafPath[0] = bytes1(0x30 | _nibAt(keyHash, 1));
        // path[1..31]: pack keyHash[0..30] nibbles shifted by 1 (nibbles 2..63 of keyHash).
        for (uint256 i = 1; i < 32; i++) {
            // nibble (2i) = high nibble of keyHash[i], nibble (2i+1) = low nibble of keyHash[i]
            // path nibble at index 2i = pathNibAt(2i) = high nibble of path[i]
            // should match keyHash nibble 2i (j = 2i-1 → keyIdx+j = 1+2i-1 = 2i)
            // We need pathNibAt(2i) = nibAt(keyHash, 2i) and pathNibAt(2i+1) = nibAt(keyHash, 2i+1)
            // For path[i] (i>=1): high nibble = nibAt(keyHash, 2i), low nibble = nibAt(keyHash, 2i+1)
            // = high nibble of keyHash[i], low nibble of keyHash[i] = keyHash[i]
            leafPath[i] = keyHash[i];
        }
        // Handle the special alignment: path nibble at position 1 (low nibble of path[0])
        // should match keyHash nibble 1 = low nibble of keyHash[0]. Already set above.
        // path nibble at position 2 (high nibble of path[1]) should match keyHash nibble 2 = high of keyHash[1].
        // But path[1] = keyHash[1] whose high nibble IS keyHash nibble 2. ✓
        // So path[1] high nibble = high nibble of keyHash[1] = nibAt(keyHash, 2) ✓
        // And path[1] low nibble = low nibble of keyHash[1] = nibAt(keyHash, 3) ✓

        bytes[] memory leafItems = new bytes[](2);
        leafItems[0] = RLP.encode(leafPath);
        leafItems[1] = RLP.encode(value);
        bytes memory leafNode = RLP.encode(leafItems);
        bytes32 leafHash = keccak256(leafNode);

        // Branch node: items[nib0] = leafHash, rest empty.
        bytes[] memory branchItems = new bytes[](17);
        for (uint256 i = 0; i < 16; i++) {
            branchItems[i] = i == nib0 ? RLP.encode(abi.encodePacked(leafHash)) : RLP.encode(new bytes(0));
        }
        branchItems[16] = RLP.encode(new bytes(0));
        bytes memory branchNode = RLP.encode(branchItems);

        root = keccak256(branchNode);
        proof = new bytes[](2);
        proof[0] = branchNode;
        proof[1] = leafNode;
    }

    /// @dev Extension (63 nibbles) → branch1 (consumes nibble 63) → branch2 terminal.
    ///      Uses KEY_HASH_1: nibbles 0-62=0, nibble63=1.
    function _branchTerminalProof(bytes32 keyHash, bytes memory value)
        internal
        pure
        returns (bytes32 root, bytes[] memory proof)
    {
        // branch2 terminal: items[16] = value, rest empty.
        bytes[] memory b2Items = new bytes[](17);
        for (uint256 i = 0; i < 16; i++) {
            b2Items[i] = RLP.encode(new bytes(0));
        }
        b2Items[16] = RLP.encode(value);
        bytes memory branch2 = RLP.encode(b2Items);
        bytes32 b2Hash = keccak256(branch2);

        // branch1: items[nibble63] = b2Hash, rest empty.
        uint8 nib63 = _nibAt(keyHash, 63);
        bytes[] memory b1Items = new bytes[](17);
        for (uint256 i = 0; i < 16; i++) {
            b1Items[i] = i == nib63 ? RLP.encode(abi.encodePacked(b2Hash)) : RLP.encode(new bytes(0));
        }
        b1Items[16] = RLP.encode(new bytes(0));
        bytes memory branch1 = RLP.encode(b1Items);
        bytes32 b1Hash = keccak256(branch1);

        // Extension: 63 nibbles (odd, extension) covering keyHash nibbles 0-62.
        // For an odd path, extPath[k] (k>=1) packs keyHash nibbles (2k-1) and (2k),
        // NOT keyHash[k] which would pack nibbles (2k) and (2k+1).
        bytes memory extPath = new bytes(32);
        extPath[0] = bytes1(0x10 | _nibAt(keyHash, 0));
        for (uint256 k = 1; k < 32; k++) {
            extPath[k] = bytes1(uint8((_nibAt(keyHash, 2 * k - 1) << 4) | _nibAt(keyHash, 2 * k)));
        }
        bytes[] memory extItems = new bytes[](2);
        extItems[0] = RLP.encode(extPath);
        extItems[1] = RLP.encode(abi.encodePacked(b1Hash));
        bytes memory extNode = RLP.encode(extItems);

        root = keccak256(extNode);
        proof = new bytes[](3);
        proof[0] = extNode;
        proof[1] = branch1;
        proof[2] = branch2;
    }

    /// @dev Extension (32 nibbles, even) → leaf (32 nibbles, even). Uses KEY_HASH_0 (all zeros).
    function _extensionThenLeafProof(bytes32 keyHash, bytes memory value)
        internal
        pure
        returns (bytes32 root, bytes[] memory proof)
    {
        // Leaf: 32 nibbles (even), covering keyHash nibbles 32-63.
        bytes memory leafPath = new bytes(17); // totalNibbles=34, pathLen=32
        leafPath[0] = 0x20; // leaf, even
        for (uint256 i = 0; i < 16; i++) {
            leafPath[i + 1] = keyHash[i + 16];
        }
        bytes[] memory leafItems = new bytes[](2);
        leafItems[0] = RLP.encode(leafPath);
        leafItems[1] = RLP.encode(value);
        bytes memory leafNode = RLP.encode(leafItems);
        bytes32 leafHash = keccak256(leafNode);

        // Extension: 32 nibbles (even), covering keyHash nibbles 0-31.
        bytes memory extPath = new bytes(17); // totalNibbles=34, pathLen=32
        extPath[0] = 0x00; // ext, even — low nibble must be 0
        for (uint256 i = 0; i < 16; i++) {
            extPath[i + 1] = keyHash[i];
        }
        bytes[] memory extItems = new bytes[](2);
        extItems[0] = RLP.encode(extPath);
        extItems[1] = RLP.encode(abi.encodePacked(leafHash));
        bytes memory extNode = RLP.encode(extItems);

        root = keccak256(extNode);
        proof = new bytes[](2);
        proof[0] = extNode;
        proof[1] = leafNode;
    }

    /// @dev Branch node where the slot for keyHash's nibble0 is empty → MPTKeyAbsent / getOrEmpty returns [].
    function _branchAbsentProof(
        bytes32 /*keyHash*/
    )
        internal
        pure
        returns (bytes32 root, bytes[] memory proof)
    {
        bytes[] memory branchItems = new bytes[](17);
        for (uint256 i = 0; i < 17; i++) {
            branchItems[i] = RLP.encode(new bytes(0)); // all slots empty → key absent for any nibble
        }
        bytes memory branchNode = RLP.encode(branchItems);
        root = keccak256(branchNode);
        proof = new bytes[](1);
        proof[0] = branchNode;
    }

    /// @dev Extension (32 even nibbles) with no following proof node → MPTProofEndedEarly.
    function _extensionNodeOnly(bytes32 keyHash) internal pure returns (bytes32 root, bytes[] memory proof) {
        bytes32 fakeChildHash = keccak256("nonexistent");
        bytes memory extPath = new bytes(17);
        extPath[0] = 0x00; // ext, even
        for (uint256 i = 0; i < 16; i++) {
            extPath[i + 1] = keyHash[i];
        }
        bytes[] memory extItems = new bytes[](2);
        extItems[0] = RLP.encode(extPath);
        extItems[1] = RLP.encode(abi.encodePacked(fakeChildHash));
        bytes memory extNode = RLP.encode(extItems);
        root = keccak256(extNode);
        proof = new bytes[](1);
        proof[0] = extNode;
    }

    function _nibAt(bytes32 keyHash, uint256 i) internal pure returns (uint8) {
        uint8 b = uint8(keyHash[i >> 1]);
        return (i & 1 == 0) ? (b >> 4) : (b & 0x0f);
    }

    // ── MPTInlineNodeUnsupported: branch node child ────────────────────────────

    /// @dev Branch node with an inline (< 32-byte) child in slot nibble0 →
    ///      verifyInclusion reverts with MPTInlineNodeUnsupported.
    function test_verifyInclusion_inlineBranchChild_reverts() public {
        bytes[] memory branchItems = new bytes[](17);
        for (uint256 i = 0; i < 16; i++) {
            // slot 0 gets a 4-byte inline reference — too short to be a hash
            branchItems[i] = i == 0 ? RLP.encode(bytes(hex"deadbeef")) : RLP.encode(new bytes(0));
        }
        branchItems[16] = RLP.encode(new bytes(0));
        bytes memory branchNode = RLP.encode(branchItems);
        bytes32 root = keccak256(branchNode);
        bytes[] memory proof = new bytes[](1);
        proof[0] = branchNode;

        // KEY_HASH_0 nibble0 = 0 → hits slot 0 → inline child → revert
        vm.expectRevert(MerklePatriciaProof.MPTInlineNodeUnsupported.selector);
        h.verifyInclusion(root, KEY_HASH_0, proof);
    }

    /// @dev Same inline-child scenario in getOrEmpty — also reverts.
    function test_getOrEmpty_inlineBranchChild_reverts() public {
        bytes[] memory branchItems = new bytes[](17);
        for (uint256 i = 0; i < 16; i++) {
            branchItems[i] = i == 0 ? RLP.encode(bytes(hex"deadbeef")) : RLP.encode(new bytes(0));
        }
        branchItems[16] = RLP.encode(new bytes(0));
        bytes memory branchNode = RLP.encode(branchItems);
        bytes32 root = keccak256(branchNode);
        bytes[] memory proof = new bytes[](1);
        proof[0] = branchNode;

        vm.expectRevert(MerklePatriciaProof.MPTInlineNodeUnsupported.selector);
        h.getOrEmpty(root, KEY_HASH_0, proof);
    }

    // ── MPTInlineNodeUnsupported: extension node child ─────────────────────────

    /// @dev Extension node whose child pointer is 4 bytes (inline, not a 32-byte hash).
    function test_verifyInclusion_inlineExtensionChild_reverts() public {
        bytes memory extPath = new bytes(17);
        extPath[0] = 0x00; // extension, even
        bytes[] memory extItems = new bytes[](2);
        extItems[0] = RLP.encode(extPath);
        extItems[1] = RLP.encode(bytes(hex"deadbeef")); // inline child, not 32 bytes
        bytes memory extNode = RLP.encode(extItems);
        bytes32 root = keccak256(extNode);
        bytes[] memory proof = new bytes[](1);
        proof[0] = extNode;

        vm.expectRevert(MerklePatriciaProof.MPTInlineNodeUnsupported.selector);
        h.verifyInclusion(root, KEY_HASH_0, proof);
    }

    /// @dev Same inline extension child in getOrEmpty — also reverts.
    function test_getOrEmpty_inlineExtensionChild_reverts() public {
        bytes memory extPath = new bytes(17);
        extPath[0] = 0x00; // extension, even
        bytes[] memory extItems = new bytes[](2);
        extItems[0] = RLP.encode(extPath);
        extItems[1] = RLP.encode(bytes(hex"deadbeef")); // inline
        bytes memory extNode = RLP.encode(extItems);
        bytes32 root = keccak256(extNode);
        bytes[] memory proof = new bytes[](1);
        proof[0] = extNode;

        vm.expectRevert(MerklePatriciaProof.MPTInlineNodeUnsupported.selector);
        h.getOrEmpty(root, KEY_HASH_0, proof);
    }

    // ── getOrEmpty: MPTInvalidHashRef, MPTInvalidNode, MPTProofEndedEarly ─────

    function test_getOrEmpty_hashMismatch_reverts() public {
        (bytes32 root, bytes[] memory proof) = _leafProof(KEY_HASH_0, hex"cafe");
        vm.expectRevert(MerklePatriciaProof.MPTInvalidHashRef.selector);
        h.getOrEmpty(bytes32(uint256(root) ^ 1), KEY_HASH_0, proof);
    }

    function test_getOrEmpty_invalidNode_reverts() public {
        bytes[] memory items = new bytes[](3);
        items[0] = RLP.encode(bytes(hex"aa"));
        items[1] = RLP.encode(bytes(hex"bb"));
        items[2] = RLP.encode(bytes(hex"cc"));
        bytes memory badNode = RLP.encode(items);
        bytes32 root = keccak256(badNode);
        bytes[] memory proof = new bytes[](1);
        proof[0] = badNode;
        vm.expectRevert(MerklePatriciaProof.MPTInvalidNode.selector);
        h.getOrEmpty(root, KEY_HASH_0, proof);
    }

    function test_getOrEmpty_proofEndedEarly_reverts() public {
        (bytes32 root, bytes[] memory extOnly) = _extensionNodeOnly(KEY_HASH_0);
        vm.expectRevert(MerklePatriciaProof.MPTProofEndedEarly.selector);
        h.getOrEmpty(root, KEY_HASH_0, extOnly);
    }

    // ── verifyInclusion: leaf keyIdx != 64 (leaf consumed before full key) ─────

    /// @dev A leaf covering 32 nibbles with no preceding branch: after traversal
    ///      keyIdx=32 ≠ 64 → MPTKeyMismatch (leaf reached too early).
    function test_verifyInclusion_leafKeyNotFullyConsumed_reverts() public {
        // Leaf path: even prefix, 32 nibbles (totalNibbles=34, pathLen=32).
        bytes memory leafPath = new bytes(17); // 17 bytes → 34 nibbles → pathLen=32
        leafPath[0] = 0x20; // leaf, even
        // payload nibbles all zero → match KEY_HASH_0 nibbles 0..31 exactly
        bytes[] memory leafItems = new bytes[](2);
        leafItems[0] = RLP.encode(leafPath);
        leafItems[1] = RLP.encode(bytes(hex"cafe"));
        bytes memory leafNode = RLP.encode(leafItems);
        bytes32 root = keccak256(leafNode);
        bytes[] memory proof = new bytes[](1);
        proof[0] = leafNode;

        // keyIdx=0+32=32 ≠ 64 → isLeaf true → keyIdx != 64 → MPTKeyMismatch
        vm.expectRevert(MerklePatriciaProof.MPTKeyMismatch.selector);
        h.verifyInclusion(root, KEY_HASH_0, proof);
    }

    // ── getOrEmpty: extension with path divergence returns empty ──────────────

    /// @dev Extension path covers nibbles 0..31 of KEY_HASH_0 (all zeros). Looked up
    ///      with KEY_HASH_1 whose nibble 63 = 1. Nibble 63 is beyond the extension
    ///      payload (only 32 nibbles), so the mismatch occurs at nibble 1 when
    ///      KEY_HASH_1 nibble 1 ≠ 0 (KEY_HASH_1 = 0x0000...0001 so nibble 1 = 0).
    ///      Actually KEY_HASH_1 = bytes32(uint256(1)): nibble 63 = 1, all others = 0.
    ///      Extension covers 32 nibbles, KEY_HASH_1 nibbles 0..31 = 0 → no divergence there.
    ///      To trigger divergence in an extension: build extension for KEY_HASH_0 path,
    ///      look up with a key that diverges within the first 32 nibbles.
    function test_getOrEmpty_extensionPathDiverges_returnsEmpty() public view {
        // KEY_HASH_A: all zeros (nibbles 0..31 = 0)
        bytes32 keyHashA = bytes32(0);
        // KEY_HASH_B: nibble 0 = 0x01 (high nibble of first byte = 1)
        bytes32 keyHashB = bytes32(uint256(0x1000000000000000000000000000000000000000000000000000000000000000));

        (bytes32 root, bytes[] memory proof) = _extensionThenLeafProof(keyHashA, hex"ff");

        // Looking up keyHashB whose nibble 0 = 1 ≠ 0 (extension path nibble 0) → diverges → empty
        bytes memory got = h.getOrEmpty(root, keyHashB, proof);
        assertEq(got.length, 0);
    }
}
