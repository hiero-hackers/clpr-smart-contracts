// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {IClprVerifier} from "@hiero-ledger/clpr/interfaces/IClprVerifier.sol";
import {SeiCometBftVerifier} from "@hiero-ledger/clpr/verifiers/evm/sei/SeiCometBftVerifier.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";
import {EndpointValidation} from "@hiero-ledger/clpr/libraries/service/EndpointValidation.sol";
import {CometBftLib} from "@hiero-ledger/clpr/libraries/proof/cometbft/CometBftLib.sol";

/// @title SeiE2EVerifier
/// @notice E2E wrapper around the real {SeiCometBftVerifier}: `verifyBundle` performs the full
///         CometBFT/ICS-23/Ed25519 verification (forwarded, no stub), while `verifyConfig` returns
///         test-configurable peer identity + seed endpoints so a two-relay Sei <-> Sei topology can
///         bootstrap its per-channel peer roster. This mirrors test/QbftE2EVerifier.sol (real
///         QBFTVerifier crypto + injected seed endpoints).
/// @dev NOT for production: only `verifyConfig` is test-shaped; the bundle proof is verified for
///      real. The channel's trust anchor is the genuine bootstrap trust anchor (peer chain id +
///      validator set this verifier was constructed with), so `verifyBundle` checks real
///      Ed25519 commit signatures against the real validator set.
contract SeiE2EVerifier is IClprVerifier {
    SeiCometBftVerifier public immutable _seiCometBftVerifier;

    error ZeroSeiCometBftVerifier();

    string private _peerChainId;
    bytes private _peerServiceAddress;
    ClprTypes.Endpoint[] private _seedEndpoints;
    string private _bootstrapChainId;
    CometBftLib.SeiValidator[] private _bootstrapValidators;

    constructor(
        string memory bootstrapChainId,
        CometBftLib.SeiValidator[] memory bootstrapValidators,
        address seiCometBftVerifier
    ) {
        if (seiCometBftVerifier == address(0)) {
            revert ZeroSeiCometBftVerifier();
        }
        _seiCometBftVerifier = SeiCometBftVerifier(seiCometBftVerifier);
        _bootstrapChainId = bootstrapChainId;
        for (uint256 i = 0; i < bootstrapValidators.length; i++) {
            _bootstrapValidators.push(bootstrapValidators[i]);
        }
    }

    /// @notice The verifier that checks commit signatures.
    function ED25519() external view returns (address) {
        return address(_seiCometBftVerifier.ED25519());
    }

    /// @notice Configure the values `verifyConfig` returns (peer identity + seed endpoints). The
    ///         peer chain id MUST match the one used to derive the channel id off-chain.
    function configure(
        string calldata peerChainId,
        bytes calldata peerServiceAddress,
        ClprTypes.Endpoint[] calldata seedEndpoints
    ) external {
        _peerChainId = peerChainId;
        _peerServiceAddress = peerServiceAddress;
        delete _seedEndpoints;
        for (uint256 i = 0; i < seedEndpoints.length; i++) {
            EndpointValidation.validateIpAddress(seedEndpoints[i].ipAddress);
            EndpointValidation.validateTlsCertificate(seedEndpoints[i].tlsCertificate);
            _seedEndpoints.push(seedEndpoints[i]);
        }
    }

    /// @notice Returns the genesis trust anchor for the PEER chain this verifier was constructed
    ///         with, in the format `_decodeTrustAnchor` expects: abi.encode(chainId, validators).
    /// @dev Cross-chain read pattern: verifier on chain X holds chain Y's bootstrap validators.
    ///      To seed chain X's own LedgerConfiguration trust anchor, call this on chain Y's verifier
    ///      and pass the result to ClprService.initialize() as both trustAnchor and trustAnchorId.
    function genesisLedgerTrustAnchor() external view returns (bytes memory) {
        return abi.encode(_bootstrapChainId, _bootstrapValidators);
    }

    /// @inheritdoc IClprVerifier
    function verifyBundle(bytes calldata proofBytes, bytes calldata trustAnchor, bytes calldata channelContext)
        external
        view
        override
        returns (
            ClprTypes.QueueMetadata memory metadata,
            bytes[] memory messagePayloads,
            bytes memory newTrustAnchor,
            bytes memory newTrustAnchorId,
            ClprTypes.ClprEndpointManifest memory newEndpointManifest
        )
    {
        return _seiCometBftVerifier.verifyBundle(proofBytes, trustAnchor, channelContext);
    }

    /// @inheritdoc IClprVerifier
    function verifyConfig(
        bytes calldata,
        bytes32 channelId,
        bytes calldata /* endpointManifestProofBytes */
    )
        external
        view
        override
        returns (
            bytes memory channelContext,
            string memory chainId,
            bytes memory serviceAddress,
            uint96 peerConfigNanos,
            ClprTypes.Throttles memory throttles,
            bytes memory initialTrustAnchor,
            bytes memory initialTrustAnchorId,
            ClprTypes.ClprEndpointManifest memory endpointManifest
        )
    {
        serviceAddress = _peerServiceAddress;
        // Genuine bootstrap trust anchor: abi.encode(chainId, SeiValidator[]) — the peer bootstrap
        // identity this verifier was constructed with. verifyBundle decodes + verifies against it.
        initialTrustAnchor = abi.encode(_bootstrapChainId, _bootstrapValidators);
        channelContext = ClprTypes.encodeChannelContext(
            ClprTypes.ChannelContext({channelId: channelId, remoteServiceAddress: _peerServiceAddress})
        );

        return (
            channelContext,
            _peerChainId,
            serviceAddress,
            0,
            ClprTypes.Throttles({
                maxMessagesPerBundle: 100,
                maxMessagePayloadBytes: 100_000,
                maxGasPerMessage: 1_000_000,
                maxQueueDepth: 1000,
                maxSyncBytes: 100_000,
                maxLocalEndpoints: 0,
                maxPeerEndpoints: 0
            }),
            initialTrustAnchor,
            "",
            ClprTypes.ClprEndpointManifest({version: 1, serviceAddress: serviceAddress, endpoints: _seedEndpoints})
        );
    }
}
