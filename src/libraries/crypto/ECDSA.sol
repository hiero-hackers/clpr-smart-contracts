// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";

library ECDSA {
    uint8 private constant PUBLIC_KEY_LENGTH = 64;
    uint8 private constant SIGNATURE_LENGTH = 65;

    /// @dev Verify ECDSA signature scoped to address(this) (ClprService).
    function _verifySignature(bytes32 id, bytes calldata pubKey, bytes calldata sig) internal view {
        if (pubKey.length != PUBLIC_KEY_LENGTH) revert ClprTypes.ClprInvalidSignature();
        bytes32 msgHash = keccak256(abi.encodePacked(id, address(this)));
        _ecrecoverCheck(msgHash, pubKey, sig);
    }

    /// @notice Shared ECDSA check: Ethereum-prefix hash then ecrecover against keccak256(pubKey).
    function _ecrecoverCheck(bytes32 msgHash, bytes calldata pubKey, bytes calldata sig) internal pure {
        if (sig.length != SIGNATURE_LENGTH) revert ClprTypes.ClprInvalidSignature();

        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }

        address recovered = ecrecover(ethSignedHash, v, r, s);
        if (recovered == address(0)) revert ClprTypes.ClprInvalidSignature();

        address expected = address(uint160(uint256(keccak256(pubKey))));
        if (recovered != expected) revert ClprTypes.ClprInvalidSignature();
    }
}
