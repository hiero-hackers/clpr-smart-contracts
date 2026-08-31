// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {ClprDeployHelper} from "@test/helpers/ClprDeployHelper.sol";
import {ClprConfig} from "../../script/ClprConfig.sol";
import {ClprService} from "@hiero-ledger/clpr/ClprService.sol";
import {ClprTypes} from "@hiero-ledger/clpr/libraries/ClprTypes.sol";
import {QBFTVerifier} from "@hiero-ledger/clpr/verifiers/evm/qbft/QBFTVerifier.sol";
import {IClprConnector} from "@hiero-ledger/clpr/interfaces/IClprConnector.sol";

/// @dev Minimal connector — always authorises outbound, pays back on inbound.
contract AlwaysAuthorize is IClprConnector {
    function authorizeOutboundMessage(bytes32, bytes calldata, bytes calldata, bytes calldata)
        external pure returns (bool) { return true; }
    function payForExecution(uint256 amount) external { payable(msg.sender).transfer(amount); }
    function onInboundMessage(bytes32, uint64, bytes calldata, bytes calldata, bytes calldata) external {}
    receive() external payable {}
}

contract QbftFixtureSetup is Script {
    string private constant LOCAL_CHAIN_ID = "eip155:1337";
    string private constant PEER_CHAIN_ID  = "eip155:1";

    // Must match IntegrationTestBase.SIGNER_PK so that the Besu-side channelId
    // equals the local test channelId.
    uint256 private constant PEER_SIGNER_PK = 0xC0DE;

    // Must match ConnectorRegistrar seed used in IntegrationTestBase._registerConnectorAndSend.
    bytes32 private constant INTEGRATION_CONNECTOR_SEED = bytes32("integration-connector");

    uint8 private constant MIN_SEALED_SIGNATURES = 2;

    // Local test app address — deterministic from Forge's deployment order in
    // IntegrationQBFTTest.setUp().  Update if the deployment order changes.
    address private constant LOCAL_APP_ADDR = 0x03A6a84cD762D9707A21605b548aaaB891562aAb;

    bytes private configProof = _readHexFile("test/verifiers/qbft/fixtures/configProof.hex");

    // Outputs — populated by helper functions and read back in run() for logging.
    ClprService private _svc;
    QBFTVerifier private _verifier;
    bytes32 private _channelId;
    bytes private _connectorId;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPk);
        _deploy(deployerPk);
        _connect(deployerPk);
        _registerConnector(deployerPk);
        _svc.sendMessage(_channelId, _connectorId, abi.encodePacked(LOCAL_APP_ADDR), hex"48454C4C4F");
        vm.stopBroadcast();

        address deployer = vm.addr(deployerPk);
        Vm.Wallet memory peerWallet = vm.createWallet(PEER_SIGNER_PK);
        ClprTypes.MessageValue memory msg1 = _svc.getMessage(_channelId, 1);

        console.log("FIXTURE_OUT::CLPR_SERVICE",  address(_svc));
        console.log("FIXTURE_OUT::QBFT_VERIFIER", address(_verifier));
        console.log("FIXTURE_OUT::CHANNEL_ID", uint256(_channelId));
        console.log("FIXTURE_OUT::PEER_SIGNER",   peerWallet.addr);
        console.log("FIXTURE_OUT::DEPLOYER",      deployer);
        console.log("FIXTURE_OUT::VALIDATOR",     vm.toString(address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)));
        console.log("FIXTURE_OUT::MSG1_PAYLOAD",  vm.toString(msg1.payload));
    }

    function _deploy(uint256 deployerPk) private {
        address deployer = vm.addr(deployerPk);
        _svc = ClprDeployHelper.deployServiceForTests(deployer, 1, LOCAL_CHAIN_ID);
        _svc.updateLedgerConfiguration(hex"1234", ClprConfig.defaultThrottles(), ClprConfig.emptySeedEndpoints(), "", "");
        _svc.updateEconomicConfiguration(ClprConfig.defaultEconomicConfig());
        _svc.registerEndpoint();
        _verifier = new QBFTVerifier(MIN_SEALED_SIGNATURES);
    }

    function _connect(uint256 deployerPk) private {
        Vm.Wallet memory peerWallet = vm.createWallet(PEER_SIGNER_PK);
        bytes memory peerPubKey = abi.encodePacked(peerWallet.publicKeyX, peerWallet.publicKeyY);
        _channelId = _svc.deriveChannelId(PEER_CHAIN_ID, peerPubKey, bytes32(0));
        _svc.registerChannel(_channelId, keccak256(abi.encodePacked(_channelId, peerPubKey)));
        bytes32 msgHash = keccak256(abi.encodePacked(_channelId, address(_svc)));
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PEER_SIGNER_PK, ethSigned);
        _svc.completeChannel(_channelId, peerPubKey, abi.encodePacked(r, s, v), bytes32(0), address(_verifier), configProof);
    }

    function _registerConnector(uint256 deployerPk) private {
        address deployer = vm.addr(deployerPk);
        uint256 connPK = uint256(keccak256(abi.encodePacked("clpr.test.connectorSigner", INTEGRATION_CONNECTOR_SEED)));
        Vm.Wallet memory connWallet = vm.createWallet(connPK);
        bytes memory connPubKey = abi.encodePacked(connWallet.publicKeyX, connWallet.publicKeyY);
        _connectorId = _svc.deriveConnectorId(_channelId, connPubKey, bytes32(0));
        _svc.registerConnector(keccak256(abi.encodePacked(_connectorId, connPubKey)));
        bytes32 ch = keccak256(abi.encodePacked(_connectorId, address(_svc)));
        bytes32 es = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", ch));
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(connPK, es);
        AlwaysAuthorize conn = new AlwaysAuthorize();
        _svc.completeConnector{value: 1 ether}(
            _connectorId, connPubKey, abi.encodePacked(cr, cs, cv), bytes32(0),
            _channelId, address(conn), deployer
        );
    }

    function _readHexFile(string memory path) internal view returns (bytes memory) {
        string memory raw = vm.readFile(path);
        bytes memory b = bytes(raw);
        while (b.length > 0 && (b[b.length - 1] == 0x0a || b[b.length - 1] == 0x0d)) {
            assembly {
                mstore(b, sub(mload(b), 1))
            }
        }
        return vm.parseBytes(string.concat("0x", string(b)));
    }
}
