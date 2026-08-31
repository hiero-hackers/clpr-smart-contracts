// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {IEd25519Verifier} from "@hiero-ledger/clpr/verifiers/evm/sei/lib/IEd25519Verifier.sol";
import {Ed25519} from "@hiero-ledger/clpr/verifiers/evm/sei/lib/Ed25519.sol";

/// @title Ed25519Verifier
/// @notice Pure-Solidity Ed25519 verification deployed as its own contract. SeiCometBftVerifier
///         calls it via {IEd25519Verifier} (an external call), which keeps the heavy verify routine
///         out of the verifier's own bytecode (size) and out of its callers' stack frames (the
///         routine is too register-heavy to inline under the repo's aggressive optimizer).
/// @dev Wraps the vendored {Ed25519} library (chengwenxi/Ed25519, Apache-2.0, ported 0.6 -> 0.8).
contract Ed25519Verifier is IEd25519Verifier {
    /// @inheritdoc IEd25519Verifier
    function verify(bytes32 pubKey, bytes calldata message, bytes calldata signature)
        external
        pure
        override
        returns (bool)
    {
        if (signature.length != 64) {
            return false;
        }
        bytes32 r = bytes32(signature[0:32]);
        bytes32 s = bytes32(signature[32:64]);
        return Ed25519.verify(pubKey, r, s, message);
    }
}
