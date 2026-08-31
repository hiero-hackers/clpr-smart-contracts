// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title Ics23Lib
/// @notice ICS-23 vector commitment proof verification (existence and non-existence)
///         for IAVL and Tendermint inner specs. Stateless; all functions are pure.
library Ics23Lib {
    // ── ICS-23 specs (matching IAVL_SPEC / TENDERMINT_SPEC) ──────────────────
    // LeafSpec: hashOp=SHA256(1), prehashKey=NO_HASH(0), prehashValue=SHA256(1),
    //           lengthOp=VAR_PROTO(1), prefix=0x00
    // IAVL inner op: minPrefix=4, maxPrefix=12, childSize=33
    uint8 internal constant IAVL_MIN_PREFIX = 4;
    uint8 internal constant IAVL_MAX_PREFIX = 12;
    uint8 internal constant IAVL_CHILD_SIZE = 33;
    // Tendermint inner op: minPrefix=1, maxPrefix=1, childSize=32
    uint8 internal constant TENDERMINT_MIN_PREFIX = 1;
    uint8 internal constant TENDERMINT_MAX_PREFIX = 1;
    uint8 internal constant TENDERMINT_CHILD_SIZE = 32;
    bytes1 internal constant LEAF_PREFIX = 0x00;

    // ── Errors ────────────────────────────────────────────────────────────────
    error KeyMismatch();
    error ValueMismatch();
    error RootMismatch();
    error NonExistenceKeyMismatch();
    error NonExistenceMissingNeighbour();
    error LeftNeighbourRootMismatch();
    error LeftNeighbourNotBeforeKey();
    error RightNeighbourRootMismatch();
    error RightNeighbourNotAfterKey();
    error RightNeighbourNotLeftMost();
    error LeftNeighbourNotRightMost();
    error LeavesNotNeighbours();
    error EmptyKey();
    error EmptyValue();
    error PathContainsLeafOp();
    error LeafPrefixMismatch();
    error LeafOpSpecMismatch();
    error HashOpNotSha256();
    error PrefixCollidesWithLeaf();
    error InvalidPrefixLength();
    error InvalidSuffixLength();

    // ── Structs ───────────────────────────────────────────────────────────────

    struct ExistenceProof {
        bytes key;
        bytes value;
        LeafOp leaf;
        InnerOp[] path;
    }

    struct LeafOp {
        uint8 hashOp;
        uint8 prehashKey;
        uint8 prehashValue;
        uint8 lengthOp;
        bytes prefix;
    }

    struct InnerOp {
        uint8 hashOp;
        bytes prefix;
        bytes suffix;
    }

    /// @dev Left/right neighbour existence proofs bracketing an absent key.
    ///      Used for zero EVM storage slots, which Sei's x/evm deletes from the
    ///      IAVL tree (so the ABCI query returns a non-existence proof, not a 32-byte value).
    struct NonExistenceProof {
        bytes key;
        bool hasLeft;
        ExistenceProof left;
        bool hasRight;
        ExistenceProof right;
    }

    // ── Membership verification ───────────────────────────────────────────────

    function verifyMembershipTendermint(ExistenceProof memory proof, bytes32 root, bytes memory key, bytes memory value)
        internal
        pure
    {
        if (keccak256(proof.key) != keccak256(key)) revert KeyMismatch();
        if (keccak256(proof.value) != keccak256(value)) revert ValueMismatch();
        bytes32 computed = existenceRootTendermint(proof);
        if (computed != root) revert RootMismatch();
    }

    function verifyMembershipIavl(ExistenceProof memory proof, bytes32 root, bytes memory key, bytes memory value)
        internal
        pure
    {
        if (keccak256(proof.key) != keccak256(key)) revert KeyMismatch();
        if (keccak256(proof.value) != keccak256(value)) revert ValueMismatch();
        bytes32 computed = existenceRootIavl(proof);
        if (computed != root) revert RootMismatch();
    }

    /// @dev Verifies an ICS-23 IAVL non-existence proof: the absent `key` is bracketed by adjacent
    ///      existing leaves (`left` < key < `right`) that both commit to `root`, and the two leaves
    ///      are genuine tree neighbours (nothing exists between them).
    function verifyNonMembershipIavl(NonExistenceProof memory nep, bytes32 root, bytes memory key) internal pure {
        if (keccak256(nep.key) != keccak256(key)) revert NonExistenceKeyMismatch();
        if (!nep.hasLeft && !nep.hasRight) revert NonExistenceMissingNeighbour();

        if (nep.hasLeft) {
            if (existenceRootIavl(nep.left) != root) revert LeftNeighbourRootMismatch();
            if (!bytesLt(nep.left.key, key)) revert LeftNeighbourNotBeforeKey();
        }
        if (nep.hasRight) {
            if (existenceRootIavl(nep.right) != root) revert RightNeighbourRootMismatch();
            if (!bytesLt(key, nep.right.key)) revert RightNeighbourNotAfterKey();
        }

        if (!nep.hasLeft) {
            if (!isLeftMost(nep.right.path)) revert RightNeighbourNotLeftMost();
        } else if (!nep.hasRight) {
            if (!isRightMost(nep.left.path)) revert LeftNeighbourNotRightMost();
        } else {
            if (!isLeftNeighbor(nep.left.path, nep.right.path)) revert LeavesNotNeighbours();
        }
    }

    // ── Root computation ──────────────────────────────────────────────────────

    function existenceRootTendermint(ExistenceProof memory proof) internal pure returns (bytes32) {
        return existenceRoot(proof, TENDERMINT_MIN_PREFIX, TENDERMINT_MAX_PREFIX, TENDERMINT_CHILD_SIZE);
    }

    function existenceRootIavl(ExistenceProof memory proof) internal pure returns (bytes32) {
        return existenceRoot(proof, IAVL_MIN_PREFIX, IAVL_MAX_PREFIX, IAVL_CHILD_SIZE);
    }

    /// @dev Applies leaf op and path inner ops, returning the root hash.
    function existenceRoot(ExistenceProof memory proof, uint8 minPrefix, uint8 maxPrefix, uint8 childSize)
        internal
        pure
        returns (bytes32)
    {
        if (proof.key.length == 0) revert EmptyKey();
        if (proof.value.length == 0) revert EmptyValue();

        // Validate leaf op (both specs: hashOp=1 SHA256, prehashKey=0, prehashValue=1 SHA256,
        //                   lengthOp=1 VAR_PROTO, prefix starts with 0x00)
        LeafOp memory leaf = proof.leaf;
        if (leaf.hashOp != 1 || leaf.prehashKey != 0 || leaf.prehashValue != 1 || leaf.lengthOp != 1) {
            revert LeafOpSpecMismatch();
        }
        if (leaf.prefix.length == 0 || leaf.prefix[0] != LEAF_PREFIX) revert LeafPrefixMismatch();

        // Apply leaf: sha256(prefix || varint(len(key)) || key || varint(len(sha256(value))) || sha256(value))
        bytes memory hashedValue = abi.encodePacked(sha256(proof.value));
        bytes memory encodedKey = abi.encodePacked(_pbVarint(proof.key.length), proof.key);
        bytes memory encodedValue = abi.encodePacked(_pbVarint(hashedValue.length), hashedValue);
        bytes32 node = sha256(abi.encodePacked(leaf.prefix, encodedKey, encodedValue));

        // Apply inner ops
        for (uint256 i = 0; i < proof.path.length; i++) {
            InnerOp memory op = proof.path[i];
            if (op.hashOp != 1) revert HashOpNotSha256();
            if (op.prefix.length > 0 && op.prefix[0] == LEAF_PREFIX) revert PrefixCollidesWithLeaf();
            uint256 maxP = uint256(maxPrefix) + uint256(childSize);
            if (op.prefix.length < minPrefix || op.prefix.length > maxP) revert InvalidPrefixLength();
            if (op.suffix.length % childSize != 0) revert InvalidSuffixLength();

            node = sha256(abi.encodePacked(op.prefix, node, op.suffix));
        }
        return node;
    }

    // ── IAVL path navigation ─────────────────────────────────────────────────

    /// @dev IAVL inner-op branch index by padding shape (InnerSpec child_order=[0,1], child_size=33,
    ///      prefix 4..12, empty_child empty): left child = suffix 33B + prefix 4..12; right child =
    ///      suffix 0 + prefix 37..45. Returns 255 for any other shape.
    function iavlBranch(InnerOp memory op) internal pure returns (uint8) {
        uint256 p = op.prefix.length;
        uint256 s = op.suffix.length;
        if (s == IAVL_CHILD_SIZE && p >= IAVL_MIN_PREFIX && p <= IAVL_MAX_PREFIX) return 0;
        if (s == 0 && p >= IAVL_MIN_PREFIX + IAVL_CHILD_SIZE && p <= IAVL_MAX_PREFIX + IAVL_CHILD_SIZE) return 1;
        return 255;
    }

    /// @dev Every step descends the left child (empty_child is empty for IAVL, so no padding holes).
    function isLeftMost(InnerOp[] memory path) internal pure returns (bool) {
        for (uint256 i; i < path.length; i++) {
            if (iavlBranch(path[i]) != 0) return false;
        }
        return true;
    }

    /// @dev Every step descends the right child.
    function isRightMost(InnerOp[] memory path) internal pure returns (bool) {
        for (uint256 i; i < path.length; i++) {
            if (iavlBranch(path[i]) != 1) return false;
        }
        return true;
    }

    /// @dev True when `left` is the immediate left neighbour of `right` (ics23 IsLeftNeighbor for
    ///      IAVL). Paths run leaf→root; strip the shared root-side suffix, require the first
    ///      divergent step to be left-then-right siblings, then the sub-paths below must be
    ///      right-most (left) / left-most (right).
    function isLeftNeighbor(InnerOp[] memory l, InnerOp[] memory r) internal pure returns (bool) {
        int256 i = int256(l.length) - 1;
        int256 j = int256(r.length) - 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        while (i >= 0 && j >= 0 && innerOpEq(l[uint256(i)], r[uint256(j)])) {
            i--;
            j--;
        }
        if (i < 0 || j < 0) return false;
        // forge-lint: disable-next-line(unsafe-typecast)
        if (iavlBranch(l[uint256(i)]) != 0 || iavlBranch(r[uint256(j)]) != 1) return false;
        // forge-lint: disable-next-line(unsafe-typecast)
        for (uint256 k; k < uint256(i); k++) {
            if (iavlBranch(l[k]) != 1) return false;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        for (uint256 k; k < uint256(j); k++) {
            if (iavlBranch(r[k]) != 0) return false;
        }
        return true;
    }

    function innerOpEq(InnerOp memory a, InnerOp memory b) internal pure returns (bool) {
        return keccak256(a.prefix) == keccak256(b.prefix) && keccak256(a.suffix) == keccak256(b.suffix);
    }

    /// @dev Lexicographic byte comparison: true iff a < b.
    function bytesLt(bytes memory a, bytes memory b) internal pure returns (bool) {
        uint256 n = a.length < b.length ? a.length : b.length;
        for (uint256 i; i < n; i++) {
            if (uint8(a[i]) < uint8(b[i])) return true;
            if (uint8(a[i]) > uint8(b[i])) return false;
        }
        return a.length < b.length;
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    function _pbVarint(uint256 value) private pure returns (bytes memory out) {
        bytes memory tmp = new bytes(10);
        uint256 idx;
        do {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 b = uint8(value & 0x7F);
            value >>= 7;
            if (value != 0) b |= 0x80;
            tmp[idx++] = bytes1(b);
        } while (value != 0);
        out = new bytes(idx);
        for (uint256 j; j < idx; j++) {
            out[j] = tmp[j];
        }
    }
}
