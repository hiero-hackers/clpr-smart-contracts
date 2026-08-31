// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {WRAPSVerifier} from "@hiero-ledger/clpr/verifiers/hiero/wraps/WRAPSVerifier.sol";

/// @title WRAPSVerifierContract
/// @notice Deployed wrapper for the `WRAPSVerifier` library.
/// @dev `TSSVerifier` calls this contract via an external view call so that
///      the BN254Util + WRAPSVerificationKey code is deployed here rather than
///      inlined into `TSSVerifier`. The large PoseidonBN254 permutation is kept
///      in a separate `PoseidonBN254Contract` and called externally by
///      `WRAPSVerifier` via the stored `poseidon` address, keeping every
///      contract's initcode under the EIP-3860 49 152-byte cap.
contract WRAPSVerifierContract {
    /// @notice Deployed `PoseidonBN254Contract` address, called externally by `WRAPSVerifier`.
    address public immutable POSEIDON;

    /// @param poseidon_ Deployed `PoseidonBN254Contract` address.
    constructor(address poseidon_) {
        POSEIDON = poseidon_;
    }

    /// @notice Verify a 704-byte WRAPS abProof. Delegates to `WRAPSVerifier.verify`.
    /// @param abProof   704-byte Arkworks-serialized ProofData.
    /// @param hintsVk   1096-byte hinTS verification key.
    /// @param ledgerId  32-byte trust-anchor ledger id (raw LE Fr bytes).
    /// @return True if the proof is valid.
    function verify(bytes calldata abProof, bytes calldata hintsVk, bytes calldata ledgerId, bool skipPoseidon)
        external
        view
        returns (bool)
    {
        return WRAPSVerifier.verify(abProof, hintsVk, ledgerId, skipPoseidon ? address(0) : POSEIDON);
    }
}
