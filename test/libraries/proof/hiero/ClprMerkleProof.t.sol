// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ClprMerkleProof} from "@hiero-ledger/clpr/libraries/proof/hiero/ClprMerkleProof.sol";
import {ClprStateProof} from "@hiero-ledger/clpr/libraries/proof/hiero/ClprStateProof.sol";

contract ClprMerkleProofTest is Test {
    // ─────────────────────────────────────────────────────────────────────
    // Dummy CLPR test fixtures
    //
    // Stand-in byte values for `MerklePath` content variants. Shapes match
    // what the decoder produces (raw protobuf bytes for the three leaf
    // kinds, a raw hash for `explicit_hash`), but the byte payloads
    // themselves are arbitrary — these tests exercise the merkle
    // library's structural behavior, not protobuf inner-decoding.
    // ─────────────────────────────────────────────────────────────────────

    bytes internal constant DUMMY_STATE_ITEM_LEAF = hex"cafe01";
    bytes internal constant DUMMY_BLOCK_ITEM_LEAF = hex"beef02";
    bytes internal constant DUMMY_TIMESTAMP_LEAF = hex"feed03";
    /// @dev 48-byte stand-in for a SHA-384 sibling hash. Real spine paths
    ///      carry 48-byte hashes; using the same width here keeps the
    ///      proto-shaped fixture realistic.
    bytes internal constant DUMMY_EXPLICIT_HASH =
        hex"abcdef0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f";
    bytes internal constant DUMMY_SECOND_EXPLICIT_HASH =
        hex"112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff001122";

    function test_chainedRoot_revertsOnStartIndexOutOfRange() public {
        ClprStateProof.MerklePath[] memory paths = _oneOf(_pathWithExplicitHash(hex"00"));

        vm.expectRevert(abi.encodeWithSelector(ClprMerkleProof.MerkleProofStartIndexOutOfRange.selector, uint256(5)));
        this.callChained(paths, 5);
    }

    function test_chainedRoot_revertsOnNextPathOutOfRange() public {
        ClprStateProof.MerklePath memory p0 = _pathWithExplicitHash(hex"00");
        p0.nextPathIndex = 99; // dangling, paths.length == 1

        ClprStateProof.MerklePath[] memory paths = _oneOf(p0);

        vm.expectRevert(abi.encodeWithSelector(ClprMerkleProof.MerkleProofChainOutOfRange.selector, uint256(99)));
        this.callChained(paths, 0);
    }

    function test_chainedRoot_revertsOnCycle() public {
        // p0: starting path with content; p1 and p2 form a cycle (each with no
        // content, so the intermediate-content check passes). Walker enforces
        // hopGuard ≤ paths.length and reverts with MerkleProofChainCycle.
        ClprStateProof.MerklePath memory p0 = _pathWithExplicitHash(hex"aa");
        p0.nextPathIndex = 1;

        ClprStateProof.MerklePath memory p1 = _emptyPath();
        p1.nextPathIndex = 2;

        ClprStateProof.MerklePath memory p2 = _emptyPath();
        p2.nextPathIndex = 1; // p1 ⇄ p2 — infinite loop without the hopGuard

        ClprStateProof.MerklePath[] memory paths = new ClprStateProof.MerklePath[](3);
        paths[0] = p0;
        paths[1] = p1;
        paths[2] = p2;

        vm.expectRevert(ClprMerkleProof.MerkleProofChainCycle.selector);
        this.callChained(paths, 0);
    }

    function test_chainedRoot_revertsOnIntermediateContent() public {
        // path[0] terminates at path[1]; path[1] has content, which the walker
        // refuses (intermediate paths must be content-free).
        ClprStateProof.MerklePath memory p0 = _pathWithExplicitHash(hex"aa");
        p0.nextPathIndex = 1;

        ClprStateProof.MerklePath memory p1 = _pathWithExplicitHash(hex"bb"); // ← shouldn't be set on a chained-into path

        ClprStateProof.MerklePath[] memory paths = new ClprStateProof.MerklePath[](2);
        paths[0] = p0;
        paths[1] = p1;

        vm.expectRevert(abi.encodeWithSelector(ClprMerkleProof.MerkleProofChainHasContent.selector, uint256(1)));
        this.callChained(paths, 0);
    }

    function callChained(ClprStateProof.MerklePath[] calldata paths, uint256 startIndex)
        external
        pure
        returns (bytes memory)
    {
        ClprStateProof.MerklePath[] memory mem_ = paths;
        return ClprMerkleProof.computeChainedRoot(mem_, startIndex);
    }

    // --- findFirstPath / LeafKind -----------------------------------------

    function test_findFirstPath_returnsMaxOnEmpty() public pure {
        ClprStateProof.MerklePath[] memory paths = new ClprStateProof.MerklePath[](0);
        assertEq(
            ClprMerkleProof.findFirstPath(paths, ClprMerkleProof.LeafKind.Any),
            type(uint256).max,
            "empty paths array must yield max sentinel"
        );
    }

    function test_findFirstPath_returnsMaxWhenNoneMatchKind() public pure {
        // All paths carry only explicitHash; asking for StateItemLeaf must miss.
        ClprStateProof.MerklePath[] memory paths = new ClprStateProof.MerklePath[](3);
        paths[0] = _pathWithExplicitHash(hex"aa");
        paths[1] = _pathWithExplicitHash(hex"bb");
        paths[2] = _pathWithExplicitHash(hex"cc");

        assertEq(ClprMerkleProof.findFirstPath(paths, ClprMerkleProof.LeafKind.StateItemLeaf), type(uint256).max);
    }

    function test_findFirstPath_anyKind_matchesFirstPopulated() public pure {
        // Proto-shaped: paths[0] is prev-block spine (Hash). LeafKind.Any
        // returns the first populated path, which is index 0.
        ClprStateProof.MerklePath[] memory paths = _protoShapedPaths();
        assertEq(ClprMerkleProof.findFirstPath(paths, ClprMerkleProof.LeafKind.Any), 0);
    }

    function test_findFirstPath_stateItemLeaf_skipsSpineAndTimestamp() public pure {
        // The verifyBundle invariant: anchoring on StateItemLeaf must skip past
        // the three spine/timestamp entries and land on index 3.
        ClprStateProof.MerklePath[] memory paths = _protoShapedPaths();
        assertEq(ClprMerkleProof.findFirstPath(paths, ClprMerkleProof.LeafKind.StateItemLeaf), 3);
    }

    function test_findFirstPath_hashKind_hitsPrevBlockSpine() public pure {
        // LeafKind.Hash matches the first `hash`-bearing path (proto field 3).
        ClprStateProof.MerklePath[] memory paths = _protoShapedPaths();
        assertEq(ClprMerkleProof.findFirstPath(paths, ClprMerkleProof.LeafKind.Hash), 0);
    }

    function test_findFirstPath_timestampLeaf_findsConsensusTimestamp() public pure {
        ClprStateProof.MerklePath[] memory paths = _protoShapedPaths();
        assertEq(ClprMerkleProof.findFirstPath(paths, ClprMerkleProof.LeafKind.TimestampLeaf), 1);
    }

    function test_findFirstPath_blockItemLeaf_findsIt() public pure {
        ClprStateProof.MerklePath[] memory paths = new ClprStateProof.MerklePath[](2);
        paths[0] = _pathWithExplicitHash(hex"aa");
        paths[1] = _pathWithBlockItem(DUMMY_BLOCK_ITEM_LEAF);
        assertEq(ClprMerkleProof.findFirstPath(paths, ClprMerkleProof.LeafKind.BlockItemLeaf), 1);
    }

    // --- Helpers ----------------------------------------------------------

    function _emptyPath() internal pure returns (ClprStateProof.MerklePath memory path) {
        path.siblings = new ClprStateProof.SiblingNode[](0);
        path.nextPathIndex = ClprMerkleProof.TERMINATOR;
    }

    function _pathWithExplicitHash(bytes memory h) internal pure returns (ClprStateProof.MerklePath memory p) {
        p = _emptyPath();
        p.explicitHash = h;
    }

    function _pathWithStateItem(bytes memory leaf) internal pure returns (ClprStateProof.MerklePath memory p) {
        p = _emptyPath();
        p.stateItemLeaf = leaf;
    }

    function _pathWithBlockItem(bytes memory leaf) internal pure returns (ClprStateProof.MerklePath memory p) {
        p = _emptyPath();
        p.blockItemLeaf = leaf;
    }

    function _pathWithTimestamp(bytes memory leaf) internal pure returns (ClprStateProof.MerklePath memory p) {
        p = _emptyPath();
        p.timestampLeaf = leaf;
    }

    function _oneOf(ClprStateProof.MerklePath memory path)
        internal
        pure
        returns (ClprStateProof.MerklePath[] memory paths)
    {
        paths = new ClprStateProof.MerklePath[](1);
        paths[0] = path;
    }

    /// @dev Builds a proto-shape `MerklePath[]` matching the `paths` ordering
    ///      documented in `state_proof.proto`:
    ///        [0] prev-block-root spine — `hash` (LeafKind.Hash)
    ///        [1] consensus-timestamp leaf — `timestamp_leaf` (LeafKind.TimestampLeaf)
    ///        [2] block-root spine — `hash` (LeafKind.Hash)
    ///        [3] state-item leaf — `state_item_leaf` (LeafKind.StateItemLeaf)
    ///      Each path is self-contained (`nextPathIndex == TERMINATOR`), so the
    ///      array exercises predicate-based path discovery without the
    ///      structural complexity of a chained walk.
    function _protoShapedPaths() internal pure returns (ClprStateProof.MerklePath[] memory paths) {
        paths = new ClprStateProof.MerklePath[](4);
        paths[0] = _pathWithExplicitHash(DUMMY_EXPLICIT_HASH);
        paths[1] = _pathWithTimestamp(DUMMY_TIMESTAMP_LEAF);
        paths[2] = _pathWithExplicitHash(DUMMY_SECOND_EXPLICIT_HASH);
        paths[3] = _pathWithStateItem(DUMMY_STATE_ITEM_LEAF);
    }

    function test_chainedRoot_reverts_emptyPathContent() public {
        vm.expectRevert(ClprMerkleProof.MerkleProofNoBaseHash.selector);
        this.callChained(_oneOf(_emptyPath()), 0);
    }

    function test_chainedRoot_blockItemLeaf_returns48Bytes() public view {
        bytes memory result = this.callChained(_oneOf(_pathWithBlockItem(DUMMY_BLOCK_ITEM_LEAF)), 0);
        assertEq(result.length, 48, "SHA-384 hash must be 48 bytes");
    }

    function test_chainedRoot_timestampLeaf_returns48Bytes() public view {
        bytes memory result = this.callChained(_oneOf(_pathWithTimestamp(DUMMY_TIMESTAMP_LEAF)), 0);
        assertEq(result.length, 48, "SHA-384 hash must be 48 bytes");
    }
}
