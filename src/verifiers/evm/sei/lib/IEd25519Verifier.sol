// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

/// @title IEd25519Verifier
/// @notice Pluggable Ed25519 signature verification. SeiCometBftVerifier delegates here so the
///         Ed25519 mechanism is decoupled from any single chain's precompile: chains with an
///         EIP-665 precompile can use a thin precompile-backed verifier, while chains without one
///         (e.g. Sei v6.5.2, whose 0x09 is BLAKE2F) use the pure-Solidity Ed25519Verifier.
interface IEd25519Verifier {
    /// @param pubKey   32-byte Ed25519 public key
    /// @param message  the signed message (CometBFT canonical precommit sign-bytes)
    /// @param signature 64-byte Ed25519 signature (R||S)
    /// @return ok true iff the signature is valid for (pubKey, message)
    function verify(bytes32 pubKey, bytes calldata message, bytes calldata signature) external view returns (bool ok);
}
