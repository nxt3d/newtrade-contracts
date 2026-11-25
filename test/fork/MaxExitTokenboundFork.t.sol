// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {NewTradeBundle} from "../../src/NewTradeBundle.sol";
import {BundleDeploy} from "../helpers/BundleDeploy.sol";
import {NewTradeV2Vault} from "../legacy/NewTradeV2Vault.sol";
import {NewTradeV2VaultV2} from "../../src/NewTradeV2VaultV2.sol";
import {VaultV2Deploy, VaultV2Views} from "../helpers/VaultV2Deploy.sol";
import {
    AcceptanceMode, AssetKind, BundleState, ManifestEntry, Payout, V2Initialization
} from "../../src/NewTradeV2Types.sol";
import {ISeaport, Order, OrderParameters} from "../../src/interfaces/ISeaport.sol";
import {GasProbe, ProbeERC721} from "../VaultGasProbe.t.sol";
import {TokenboundForkValidator, TokenboundForkZone} from "./TokenboundV2Fork.t.sol";

/// @notice F-01: the largest first exit against the per-transaction gas cap, with the
/// REAL Tokenbound registry, account proxy and implementation and the real Seaport on
/// Base. Run with --isolate so each call is cold:
///   forge test --match-path test/fork/MaxExitTokenboundFork.t.sol --isolate -vv \
///     --fork-url <rpc> --fork-block-number <n> --threads 1
///
/// "min gas" is gas into the escrow proxy; the transaction limit is that plus intrinsic
/// gas (`_txLimit`). Skips without a fork.
contract MaxExitTokenboundForkTest is Test {
    using VaultV2Views for NewTradeV2VaultV2;

    address private constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address private constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address private constant ACCOUNT_PROXY = 0x55266d75D1a14E4572138116aF39863Ed6596E7F;
    address private constant IMPLEMENTATION = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    address private constant SELLER = address(0xA11CE);
    address private constant BUYER = address(0xB0B);
    uint256 private constant TX_CAP = 16_777_216;
    uint256 private constant GAS_CEILING = 60_000_000;
    uint256 private constant EXTRA_BURN_NFT = 300_000;
    uint256 private constant NFT_BIT = 1 << 32;
    uint256 private constant ALL_ENTRIES = (1 << 32) - 1;
    bytes32 private constant SALT = keccak256("max-exit");

    NewTradeBundle private receipt;
    NewTradeV2VaultV2 private vault;
    NewTradeEscrowV2 private escrow;

    modifier onFork() {
        if (SEAPORT.code.length == 0 || REGISTRY.code.length == 0 || ACCOUNT_PROXY.code.length == 0) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _deployProtocol() private {
        address[] memory payments = new address[](1);
        AssetKind[] memory kinds = new AssetKind[](0);
        address[] memory assets = new address[](0);
        AcceptanceMode[3] memory modes = [AcceptanceMode.Wildcard, AcceptanceMode.Wildcard, AcceptanceMode.Wildcard];
        address validator = address(new TokenboundForkValidator());
        address zone = address(new TokenboundForkZone());
        receipt = BundleDeploy.deploy(address(this), SEAPORT, validator, address(this));
        NewTradeV2Vault legacyVault = new NewTradeV2Vault(address(this), address(receipt), assets, kinds, modes);
        V2Initialization memory config = V2Initialization(
            address(this),
            SELLER,
            0,
            payments,
            assets,
            kinds,
            modes,
            REGISTRY,
            ACCOUNT_PROXY,
            IMPLEMENTATION,
            address(receipt),
            address(legacyVault),
            validator,
            zone,
            address(0)
        );
        NewTradeEscrowV2 logic = new NewTradeEscrowV2();
        escrow = NewTradeEscrowV2(
            payable(address(new ERC1967Proxy(address(logic), abi.encodeCall(NewTradeEscrowV2.initialize, (config)))))
        );
        receipt.bindController(address(escrow));
        legacyVault.bindController(address(escrow));
        vault = VaultV2Deploy.switchEscrowMirroring(escrow, address(receipt), assets, kinds, modes);
    }

    function _sorted(GasProbe[] memory ps) private pure {
        for (uint256 i = 1; i < ps.length; ++i) {
            GasProbe x = ps[i];
            uint256 j = i;
            for (; j > 0 && address(ps[j - 1]) > address(x); --j) {
                ps[j] = ps[j - 1];
            }
            ps[j] = x;
        }
    }

    /// `n` ERC-721 entries, each its own cold contract, plus its own controlling NFT,
    /// sold to BUYER through the real Seaport.
    function _issued(uint256 n) private returns (uint256 id, GasProbe[] memory ps, ProbeERC721 nft) {
        _deployProtocol();
        ps = new GasProbe[](n);
        for (uint256 i; i < n; ++i) {
            ProbeERC721 p = new ProbeERC721();
            p.mint(SELLER, 1);
            vm.prank(SELLER);
            p.setApprovalForAll(address(vault), true);
            ps[i] = p;
        }
        _sorted(ps);
        nft = new ProbeERC721();
        nft.mint(SELLER, 1);
        vm.prank(SELLER);
        nft.setApprovalForAll(address(vault), true);
        ManifestEntry[] memory es = new ManifestEntry[](n);
        for (uint256 i; i < n; ++i) {
            es[i] = ManifestEntry(AssetKind.ERC721, address(ps[i]), 1, 1);
        }
        uint64 deadline = uint64(block.timestamp + 1 days);
        vm.prank(SELLER);
        (bool ok, bytes memory ret) = address(escrow).call{gas: GAS_CEILING}(
            abi.encodeCall(NewTradeEscrowV2.deposit, (address(nft), 1, es, deadline))
        );
        assertTrue(ok, "deposit");
        id = abi.decode(ret, (uint256));
        uint256 price = 0.001 ether;
        Payout[] memory payouts = new Payout[](1);
        payouts[0] = Payout(payable(address(escrow)), price);
        vm.prank(SELLER);
        escrow.list(id, address(0), price, deadline, 0, payouts);
        (OrderParameters memory order,,,,) = escrow.getOrder(id);
        vm.deal(BUYER, price);
        vm.prank(BUYER);
        ISeaport(SEAPORT).fulfillOrder{value: price}(Order(order, ""), bytes32(0));
    }

    function _call(bytes memory cd, uint256 g) private returns (bool ok) {
        vm.prank(BUYER);
        (ok,) = address(escrow).call{gas: g}(cd);
    }

    function _minOk(bytes memory cd) private returns (uint256 hi) {
        uint256 lo = 21_000;
        hi = GAS_CEILING;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 s = vm.snapshotState();
            bool ok = _call(cd, mid);
            vm.revertToState(s);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
    }

    function _txLimit(uint256 g, bytes memory cd) private pure returns (uint256 t) {
        t = g + 21_000;
        for (uint256 i; i < cd.length; ++i) {
            t += cd[i] == 0 ? 4 : 16;
        }
    }

    function _arm(GasProbe[] memory ps, uint256 burn) private {
        for (uint256 i; i < ps.length; ++i) {
            ps[i].arm(address(vault), false, burn);
        }
    }

    function _run(string memory name, uint256 id, bytes memory cd) private returns (uint256 limit, uint256 held) {
        uint256 g = _minOk(cd);
        limit = _txLimit(g, cd);
        assertTrue(_call(cd, g), name);
        uint256 used = vm.lastCallGas().gasTotalUsed;
        (,, held) = vault.bundleStatus(id);
        console2.log(name);
        console2.log("  min gas into the escrow      ", g);
        console2.log("  transaction limit (intrinsic)", limit);
        console2.log("  gas used at that limit       ", used);
        console2.log("  room under 2^24              ", limit < TX_CAP ? TX_CAP - limit : 0);
        console2.log("  bits still held              ", held);
        assertLt(limit, TX_CAP, "must fit the per-transaction cap");
    }

    /// Fresh real account, expensive NFT that succeeds (so the real owner/isValidSigner
    /// check runs), then 32 entries that burn their whole budget.
    function test_RealAccount_Max_NftThen32BudgetBurners() public onFork {
        (uint256 id, GasProbe[] memory ps, ProbeERC721 nft) = _issued(32);
        _arm(ps, type(uint256).max);
        nft.arm(address(vault), false, EXTRA_BURN_NFT);
        bytes memory cd = abi.encodeCall(NewTradeEscrowV2.redeemToFreshAccount, (id, SALT));
        (, uint256 held) = _run("real account: NFT expensive success, 32 budget burners", id, cd);
        assertEq(held, ALL_ENTRIES, "the NFT left, every burner held");
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Redeeming));
        assertEq(nft.ownerOf(1), BUYER);
    }

    /// 33 expensive transfers that all succeed; each entry lands on the real account
    /// through its onERC721Received.
    function test_RealAccount_Max_33ExpensiveSuccesses() public onFork {
        (uint256 id, GasProbe[] memory ps, ProbeERC721 nft) = _issued(32);
        _arm(ps, EXTRA_BURN_NFT);
        nft.arm(address(vault), false, EXTRA_BURN_NFT);
        bytes memory cd = abi.encodeCall(NewTradeEscrowV2.redeemToFreshAccount, (id, SALT));
        (, uint256 held) = _run("real account: 33 expensive successes (300k extra each)", id, cd);
        assertEq(held, 0, "closed");
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Redeemed));
    }

    /// The same bundle with healthy tokens: what a normal largest redemption costs.
    function test_RealAccount_Max_33HealthyTransfers() public onFork {
        (uint256 id,,) = _issued(32);
        bytes memory cd = abi.encodeCall(NewTradeEscrowV2.redeemToFreshAccount, (id, SALT));
        (, uint256 held) = _run("real account: 33 healthy transfers", id, cd);
        assertEq(held, 0, "closed");
    }

    /// Largest extra burn in the NFT that still releases with the real account check
    /// (mock figure, GAS-PROBE section 1: 315,737 cold). Binary search with ample gas.
    function test_RealAccount_NftMaxBurnWithAccountCheck() public onFork {
        (uint256 id,, ProbeERC721 nft) = _issued(1);
        bytes memory cd = abi.encodeCall(NewTradeEscrowV2.redeemToFreshAccount, (id, SALT));
        uint256 lo;
        uint256 hi = 400_000;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            uint256 s = vm.snapshotState();
            nft.arm(address(vault), false, mid);
            assertTrue(_call(cd, 3_000_000));
            bool released = nft.ownerOf(1) == BUYER;
            vm.revertToState(s);
            if (released) lo = mid;
            else hi = mid - 1;
        }
        console2.log("real account: max extra burn in the NFT, account check passes", lo);
        assertGt(lo, 0);
    }
}
