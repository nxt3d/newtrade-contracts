// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {NewTradeEscrowV2} from "../src/NewTradeEscrowV2.sol";
import {NewTradeBundle} from "../src/NewTradeBundle.sol";
import {BundleDeploy} from "./helpers/BundleDeploy.sol";
import {NewTradeV2Vault} from "./legacy/NewTradeV2Vault.sol";
import {NewTradeV2VaultV2} from "../src/NewTradeV2VaultV2.sol";
import {VaultV2Deploy} from "./helpers/VaultV2Deploy.sol";
import {
    AcceptanceMode, AssetKind, Bundle, BundleState, ManifestEntry, V2Initialization
} from "../src/NewTradeV2Types.sol";
import {MockERC20, MockERC721, MockERC1155} from "./mocks/TokenMocks.sol";
import {Mock6551Registry, Mock6551Implementation} from "./helpers/ERC6551Mocks.sol";
import {MockERC721T, MockERC8048ExecutableAccount} from "./helpers/ERC8048Mocks.sol";
import {SeaportV2Mock} from "./helpers/SeaportV2Mock.sol";

contract ERC8048DiscoveryTest is Test {
    bytes4 private constant ERC8048_INTERFACE_ID = 0xdf670be1;
    string private constant BASE_INDEX_ZERO = "account[0x0001000002210500][0]";
    string private constant BASE_SEPOLIA_INDEX_ZERO = "account[0x0001000003014a3400][0]";
    address private constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;

    uint256 private constant AGENT_ID = 42;
    address private seller = address(0xA11CE);
    MockERC721T private agent;
    MockERC20 private migrationERC20;
    MockERC721 private migrationERC721;
    MockERC1155 private migrationERC1155;
    NewTradeEscrowV2 private migrationEscrow;

    function setUp() public {
        agent = new MockERC721T();
        agent.mint(seller, AGENT_ID);
    }

    function test_ERC721TAdvertisesERC8048AndStoresRaw20BaseIndexZero() public {
        vm.chainId(8453);
        address account = address(0x1234567890123456789012345678901234567890);

        vm.prank(seller);
        agent.setMetadata(AGENT_ID, BASE_INDEX_ZERO, abi.encodePacked(account));

        bytes memory value = agent.metadata(AGENT_ID, BASE_INDEX_ZERO);
        assertTrue(agent.supportsInterface(ERC8048_INTERFACE_ID));
        assertTrue(agent.supportsInterface(type(IERC165).interfaceId));
        assertEq(value.length, 20);
        assertEq(value, abi.encodePacked(account));
        assertEq(agent.metadata(AGENT_ID, "account[0x000100000202210500][0]"), bytes(""));
    }

    function test_ERC721TUsesCanonicalBaseSepoliaIndexZeroKey() public {
        vm.chainId(84532);
        address account = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);

        vm.prank(seller);
        agent.setMetadata(AGENT_ID, BASE_SEPOLIA_INDEX_ZERO, abi.encodePacked(account));

        assertEq(agent.metadata(AGENT_ID, BASE_SEPOLIA_INDEX_ZERO), abi.encodePacked(account));
        assertEq(agent.metadata(AGENT_ID, "account[0x000100000302014a3400][0]"), bytes(""));
    }

    function test_ERC721TDoesNotDiscoverIndexOneWhenIndexZeroIsMissing() public {
        vm.chainId(84532);
        address account = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);

        vm.prank(seller);
        agent.setMetadata(AGENT_ID, "account[0x0001000003014a3400][1]", abi.encodePacked(account));

        assertEq(agent.metadata(AGENT_ID, BASE_SEPOLIA_INDEX_ZERO), bytes(""));
        assertEq(agent.metadata(AGENT_ID, "account[0x0001000003014a3400][1]"), abi.encodePacked(account));
    }

    function test_ERC721TRawMalformedValuesAreNotTwentyByteAccounts() public {
        vm.chainId(84532);
        bytes memory tooShort = hex"12345678901234567890123456789012345678";
        bytes memory abiEncoded = abi.encode(address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD));

        vm.startPrank(seller);
        agent.setMetadata(AGENT_ID, BASE_SEPOLIA_INDEX_ZERO, tooShort);
        agent.setMetadata(AGENT_ID, "account[0x0001000003014a3400][1]", abiEncoded);
        vm.stopPrank();

        assertEq(agent.metadata(AGENT_ID, BASE_SEPOLIA_INDEX_ZERO).length, 19);
        assertEq(agent.metadata(AGENT_ID, "account[0x0001000003014a3400][1]").length, 32);
    }

    function test_DiscoveredAccountMigratesNftFirstWithoutOwnerOrSignerGates() public {
        vm.chainId(8453);
        migrationERC20 = new MockERC20("Bundle USD", "BUSD", 18);
        migrationERC721 = new MockERC721();
        migrationERC1155 = new MockERC1155();
        migrationEscrow = _deployEscrow(migrationERC20, migrationERC721, migrationERC1155);
        Mock6551Registry registry = new Mock6551Registry();
        MockERC8048ExecutableAccount implementation = new MockERC8048ExecutableAccount();
        address account = registry.createAccount(
            address(implementation), keccak256("erc8048-discovery"), block.chainid, address(agent), AGENT_ID
        );

        vm.prank(seller);
        agent.setMetadata(AGENT_ID, BASE_INDEX_ZERO, abi.encodePacked(account));
        bytes memory discovered = agent.metadata(AGENT_ID, BASE_INDEX_ZERO);
        assertEq(discovered.length, 20);
        assertEq(address(bytes20(discovered)), account);
        (bool hasOwner,) = account.staticcall(abi.encodeWithSignature("owner()"));
        (bool hasSigner,) =
            account.staticcall(abi.encodeWithSignature("isValidSigner(address,bytes)", seller, bytes("")));
        assertFalse(hasOwner);
        assertFalse(hasSigner);

        migrationERC20.mint(account, 20 ether);
        migrationERC721.mint(account, 7);
        migrationERC1155.mint(account, 3, 4);
        address custody = migrationEscrow.vault();
        vm.prank(seller);
        agent.setApprovalForAll(custody, true);
        migrationEscrow.setMigrationEnabled(true);

        ManifestEntry[] memory entries = new ManifestEntry[](3);
        entries[0] = ManifestEntry(AssetKind.ERC20, address(migrationERC20), 0, 20 ether);
        entries[1] = ManifestEntry(AssetKind.ERC721, address(migrationERC721), 7, 1);
        entries[2] = ManifestEntry(AssetKind.ERC1155, address(migrationERC1155), 3, 4);

        vm.recordLogs();
        vm.prank(seller);
        uint256 bundleId = migrationEscrow.depositFromAccount(
            account, address(agent), AGENT_ID, entries, uint64(block.timestamp + 1 days), keccak256("fixture")
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertNftFirst(logs);
        Bundle memory bundle = migrationEscrow.getBundle(bundleId);
        assertEq(agent.ownerOf(AGENT_ID), custody);
        assertEq(migrationERC20.balanceOf(custody), 20 ether);
        assertEq(migrationERC721.ownerOf(7), custody);
        assertEq(migrationERC1155.balanceOf(custody, 3), 4);
        assertEq(uint8(bundle.state), uint8(BundleState.Deposited));
        assertEq(bundle.seller, seller);
    }

    function _assertNftFirst(Vm.Log[] memory logs) private view {
        uint256 controllingTransfer = type(uint256).max;
        uint256 firstAssetTransfer = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(agent) && logs[i].topics.length == 4) controllingTransfer = i;
            if (
                logs[i].emitter == address(migrationERC20) && logs[i].topics.length == 3
                    && firstAssetTransfer == type(uint256).max
            ) {
                firstAssetTransfer = i;
            }
        }
        assertLt(controllingTransfer, firstAssetTransfer);
    }

    function _deployEscrow(MockERC20 erc20, MockERC721 extra721, MockERC1155 erc1155)
        private
        returns (NewTradeEscrowV2 escrow)
    {
        vm.etch(SEAPORT, address(new SeaportV2Mock()).code);
        address[] memory payments = new address[](1);
        payments[0] = address(0);
        address[] memory tokens = new address[](4);
        tokens[0] = address(erc20);
        tokens[1] = address(agent);
        tokens[2] = address(extra721);
        tokens[3] = address(erc1155);
        AssetKind[] memory kinds = new AssetKind[](4);
        kinds[0] = AssetKind.ERC20;
        kinds[1] = AssetKind.ERC721;
        kinds[2] = AssetKind.ERC721;
        kinds[3] = AssetKind.ERC1155;
        AcceptanceMode[3] memory modes = [AcceptanceMode.Allowlist, AcceptanceMode.Allowlist, AcceptanceMode.Allowlist];

        NewTradeBundle receipt = BundleDeploy.deploy(address(this), SEAPORT, SEAPORT, address(this));
        NewTradeV2Vault legacyVault = new NewTradeV2Vault(address(this), address(receipt), tokens, kinds, modes);
        Mock6551Registry registry = new Mock6551Registry();
        Mock6551Implementation accountImplementation = new Mock6551Implementation();
        V2Initialization memory initialization = V2Initialization(
            address(this),
            address(0xFEE),
            250,
            payments,
            tokens,
            kinds,
            modes,
            address(registry),
            address(accountImplementation),
            address(accountImplementation),
            address(receipt),
            address(legacyVault),
            SEAPORT,
            SEAPORT,
            address(0)
        );
        NewTradeEscrowV2 implementation = new NewTradeEscrowV2();
        escrow = NewTradeEscrowV2(
            payable(address(
                new ERC1967Proxy(address(implementation), abi.encodeCall(NewTradeEscrowV2.initialize, (initialization)))
            ))
        );
        receipt.bindController(address(escrow));
        legacyVault.bindController(address(escrow));
        NewTradeV2VaultV2 vault = VaultV2Deploy.switchEscrowMirroring(escrow, address(receipt), tokens, kinds, modes);
    }
}
