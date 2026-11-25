// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {NewTradeBundle} from "../../src/NewTradeBundle.sol";
import {NewTradeV2Vault} from "../legacy/NewTradeV2Vault.sol";
import {NewTradeV2VaultV2} from "../../src/NewTradeV2VaultV2.sol";
import {AcceptanceMode, AssetKind, ManifestEntry, Payout, V2Initialization} from "../../src/NewTradeV2Types.sol";
import {OrderParameters} from "../../src/interfaces/ISeaport.sol";
import {MockERC20, MockERC721, MockERC1155} from "../mocks/TokenMocks.sol";
import {BundleDeploy} from "../helpers/BundleDeploy.sol";
import {SeaportV2Mock} from "../helpers/SeaportV2Mock.sol";
import {VaultV2Deploy} from "../helpers/VaultV2Deploy.sol";
import {
    Mock6551Registry,
    Mock6551Implementation,
    MockTokenboundAccountProxy,
    ToggleReleaseFailureERC20
} from "../helpers/ERC6551Mocks.sol";
import {ProbeERC721} from "../VaultGasProbe.t.sol";

/// Bundle state as a plain number, for the shell driver.
contract LocalStateReader {
    function state(NewTradeEscrowV2 escrow, uint256 id) external view returns (uint8) {
        return uint8(escrow.getBundle(id).state);
    }
}

/// @notice LOCAL ONLY (anvil, its public test keys): deploys the escrow and proxied vault
/// and parks bundles for test/rpc/estimate-and-execute.sh, which asks the node for
/// eth_estimateGas and sends each exit at exactly the returned limit. Never point this at
/// a live network.
contract LocalGasGuardSetup is Script {
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    uint256 constant PRICE = 1 ether;

    function setup() external {
        vm.startBroadcast();
        address me = msg.sender;
        SeaportV2Mock(SEAPORT).setCounter(42);
        SeaportV2Mock(SEAPORT).setDomainSeparator(keccak256("BASE_SEAPORT_1_6_DOMAIN"));
        MockERC20 erc20 = new MockERC20("L", "L", 18);
        MockERC721 control = new MockERC721();
        MockERC721 extra = new MockERC721();
        MockERC1155 m1155 = new MockERC1155();
        ToggleReleaseFailureERC20 toggle = new ToggleReleaseFailureERC20();
        Mock6551Registry registry = new Mock6551Registry();
        Mock6551Implementation impl = new Mock6551Implementation();
        MockTokenboundAccountProxy accountProxy = new MockTokenboundAccountProxy(address(impl));
        address[] memory payments = new address[](1);
        payments[0] = address(erc20);
        address[] memory none = new address[](0);
        AssetKind[] memory noKinds = new AssetKind[](0);
        AcceptanceMode[3] memory disabled;
        NewTradeBundle receipt = BundleDeploy.deploy(me, SEAPORT, SEAPORT, me);
        NewTradeV2Vault legacy = new NewTradeV2Vault(me, address(receipt), none, noKinds, disabled);
        V2Initialization memory c = V2Initialization(
            me,
            address(0xFEE),
            250,
            payments,
            none,
            noKinds,
            disabled,
            address(registry),
            address(accountProxy),
            address(impl),
            address(receipt),
            address(legacy),
            SEAPORT,
            SEAPORT,
            address(0)
        );
        NewTradeEscrowV2 escrow = NewTradeEscrowV2(
            payable(
                address(
                    new ERC1967Proxy(address(new NewTradeEscrowV2()), abi.encodeCall(NewTradeEscrowV2.initialize, (c)))
                )
            )
        );
        receipt.bindController(address(escrow));
        legacy.bindController(address(escrow));
        NewTradeV2VaultV2 vault = VaultV2Deploy.switchEscrow(escrow, address(receipt));
        for (uint256 i; i < 3; ++i) {
            escrow.setAssetAcceptanceMode(AssetKind(i), AcceptanceMode.Wildcard);
        }
        address v = address(vault);
        control.setApprovalForAll(v, true);
        extra.setApprovalForAll(v, true);
        m1155.setApprovalForAll(v, true);
        erc20.approve(v, type(uint256).max);
        toggle.approve(v, type(uint256).max);
        erc20.mint(me, 100 ether);
        toggle.mint(me, 100 ether);
        m1155.mint(me, 3, 100);
        uint64 deadline = uint64(block.timestamp + 1 days);

        uint256[3] memory ids;
        for (uint256 i; i < 2; ++i) {
            uint256 tid = 10 + i;
            control.mint(me, tid);
            extra.mint(me, tid);
            ManifestEntry[] memory es = new ManifestEntry[](3);
            es[0] = ManifestEntry(AssetKind.ERC20, address(erc20), 0, 1 ether);
            es[1] = ManifestEntry(AssetKind.ERC721, address(extra), tid, 1);
            es[2] = ManifestEntry(AssetKind.ERC1155, address(m1155), 3, 4);
            ids[i] = escrow.deposit(address(control), tid, es, deadline);
        }
        control.mint(me, 20);
        ManifestEntry[] memory one = new ManifestEntry[](1);
        one[0] = ManifestEntry(AssetKind.ERC20, address(toggle), 0, 1 ether);
        ids[2] = escrow.deposit(address(control), 20, one, deadline);

        Payout[] memory ps = new Payout[](1);
        ps[0] = Payout(payable(address(escrow)), PRICE);
        escrow.list(ids[1], address(erc20), PRICE, deadline, 0, ps);

        // The largest bundle: 32 distinct budget-burning ERC-721 contracts and a burning NFT.
        ProbeERC721[] memory burners = new ProbeERC721[](32);
        for (uint256 i; i < 32; ++i) {
            burners[i] = new ProbeERC721();
        }
        for (uint256 i = 1; i < 32; ++i) {
            ProbeERC721 x = burners[i];
            uint256 j = i;
            for (; j > 0 && address(burners[j - 1]) > address(x); --j) {
                burners[j] = burners[j - 1];
            }
            burners[j] = x;
        }
        ManifestEntry[] memory big = new ManifestEntry[](32);
        for (uint256 i; i < 32; ++i) {
            burners[i].mint(me, 1);
            burners[i].setApprovalForAll(v, true);
            big[i] = ManifestEntry(AssetKind.ERC721, address(burners[i]), 1, 1);
        }
        ProbeERC721 bigNft = new ProbeERC721();
        bigNft.mint(me, 1);
        bigNft.setApprovalForAll(v, true);
        uint256 bigId = escrow.deposit(address(bigNft), 1, big, deadline);
        for (uint256 i; i < 32; ++i) {
            burners[i].arm(v, false, type(uint256).max);
        }
        bigNft.arm(v, false, type(uint256).max);
        LocalStateReader reader = new LocalStateReader();
        vm.stopBroadcast();

        console2.log("ESCROW", address(escrow));
        console2.log("VAULT", v);
        console2.log("TOGGLE", address(toggle));
        console2.log("READER", address(reader));
        console2.log("ID_A", ids[0]);
        console2.log("ID_B", ids[1]);
        console2.log("ID_C", ids[2]);
        console2.log("ID_MAX", bigId);
    }

    function issue(NewTradeEscrowV2 escrow, uint256 id, address buyer) external {
        (OrderParameters memory p,,,,) = escrow.getOrder(id);
        vm.startBroadcast();
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        vm.stopBroadcast();
    }
}
