// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {ClprService} from "@hiero-ledger/clpr/ClprService.sol";
import {ClprTestBase} from "@test/helpers/ClprTestBase.sol";

import {Safe} from "safe-smart-account/contracts/Safe.sol";
import {SafeProxyFactory} from "safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {Enum} from "safe-smart-account/contracts/libraries/Enum.sol";

/// @notice Integration test exercising a REAL Safe (v1.5.0) multisig as the owner
///         of ClprService. A 2-of-3 Safe is deployed, ClprService ownership is
///         transferred to it, and an owner-only function (setClprEnabled) is
///         executed through the Safe's execTransaction — proving the threshold is
///         actually enforced, not merely that some address can call onlyOwner.
contract SafeSmartAccountTest is ClprTestBase {
    // The initial (pre-Safe) owner used at deployment.
    address internal deployerOwner = makeAddr("deployerOwner");

    // Three Safe owners with known private keys so we can sign in-test.
    address internal owner1;
    uint256 internal pk1;
    address internal owner2;
    uint256 internal pk2;
    address internal owner3;
    uint256 internal pk3;

    Safe internal safe; // the deployed Safe proxy (cast to the Safe interface)

    // Re-declared locally so vm.expectEmit can match by signature.
    event ClprEnabledChanged(bool enabled);

    function setUp() public override {
        (owner1, pk1) = makeAddrAndKey("safeOwner1");
        (owner2, pk2) = makeAddrAndKey("safeOwner2");
        (owner3, pk3) = makeAddrAndKey("safeOwner3");

        // --- Deploy a real Safe: singleton + factory + proxy, 2-of-3 ---
        Safe singleton = new Safe();
        SafeProxyFactory factory = new SafeProxyFactory();

        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        bytes memory initializer = abi.encodeWithSelector(
            Safe.setup.selector,
            owners,
            uint256(2), // threshold: 2 of 3
            address(0), // to
            bytes(""), // data
            address(0), // fallbackHandler
            address(0), // paymentToken
            uint256(0), // payment
            payable(address(0)) // paymentReceiver
        );

        safe = Safe(payable(address(factory.createProxyWithNonce(address(singleton), initializer, 0))));

        super.setUp();
        service.transferOwnership(address(safe));

        assertEq(service.owner(), address(safe), "Safe should own ClprService");
    }

    /// Positive: 2 valid owner signatures clear the threshold and the owner-only
    /// call executes. _clprEnabled starts true, so toggling to false is a real
    /// state change; the event is emitted by AdminLogic but logged with the ClprService
    /// (ClprService) as emitter due to delegatecall.
    function test_SafeExecutesOwnerOnlyCallWithThresholdSignatures() public {
        bytes memory data = abi.encodeWithSelector(ClprService.setClprEnabled.selector, false);

        bytes memory signatures = _collectSignatures(data, safe.nonce(), pk1, owner1, pk2, owner2);

        vm.expectEmit(true, true, true, true, address(service));
        emit ClprEnabledChanged(false);

        bool success = safe.execTransaction(
            address(service), 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), signatures
        );
        assertTrue(success, "execTransaction should succeed with 2 of 3 signatures");
    }

    /// Negative: a single signature is below the 2-of-3 threshold, so the Safe
    /// must reject it. This is the assertion that proves the multisig property —
    /// an EOA owner could never enforce this. GS020 = signatures data too short.
    function test_SafeRejectsSubThresholdSignature() public {
        bytes memory data = abi.encodeWithSelector(ClprService.setClprEnabled.selector, false);

        bytes32 txHash = safe.getTransactionHash(
            address(service), 0, data, Enum.Operation.Call, 0, 0, 0, address(0), address(0), safe.nonce()
        );

        // Only ONE signature — below threshold.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk1, txHash);
        bytes memory oneSig = abi.encodePacked(r, s, v);

        vm.expectRevert(bytes("GS020")); // Safe: signatures data too short
        safe.execTransaction(
            address(service), 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), oneSig
        );
    }

    /// @dev Signs `txHash` with two owner keys and returns their 65-byte
    ///      signatures concatenated in ASCENDING signer-address order, which is
    ///      what Safe.checkSignatures requires. Getting this order wrong causes a
    ///      GS026 (invalid owner) revert even when both signatures are valid.
    function _collectSignatures(
        bytes memory data,
        uint256 nonce,
        uint256 pkA,
        address addrA,
        uint256 pkB,
        address addrB
    ) internal view returns (bytes memory) {
        bytes32 txHash = safe.getTransactionHash(
            address(service), 0, data, Enum.Operation.Call, 0, 0, 0, address(0), address(0), nonce
        );

        (uint8 vA, bytes32 rA, bytes32 sA) = vm.sign(pkA, txHash);
        (uint8 vB, bytes32 rB, bytes32 sB) = vm.sign(pkB, txHash);

        bytes memory sigA = abi.encodePacked(rA, sA, vA);
        bytes memory sigB = abi.encodePacked(rB, sB, vB);

        // Concatenate in ascending address order.
        return addrA < addrB ? abi.encodePacked(sigA, sigB) : abi.encodePacked(sigB, sigA);
    }
}
