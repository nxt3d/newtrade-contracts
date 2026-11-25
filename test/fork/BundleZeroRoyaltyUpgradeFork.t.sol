// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {NewTradeBundle} from "../../src/NewTradeBundle.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {BundleState, RoyaltySnapshot} from "../../src/NewTradeV2Types.sol";
import {ISeaport, Order, OrderParameters} from "../../src/interfaces/ISeaport.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {BundleForkBase} from "./BundleForkBase.sol";
import {FeeForkZoneStub, IStrictRegistryArm} from "./EscrowFeeFromProceedsUpgradeFork.t.sol";

/**
 * zero-royalty-wrapper (item 62(3)): the Bundle-only UUPS upgrade REHEARSED on Base.
 *
 * THE LIVE WORLD at the pinned block: proxy 0x5990…6185 runs the non-transferable
 * implementation 0x9182dC37…8ab3; its owner is 0x9a70…cFb2 (acceptOwnership tx
 * 0xb27e8bf2…d53c, block 61,400,639); bundles 1..12 exist in the escrow, #11 and #12
 * are listed, and OpenSea's creator-fee schedule followed the Bundle's ERC-2981 answer
 * (5% to 0xF8e0) and rejected escrow orders.
 *
 * WHAT THIS PROVES, with the new implementation deployed from THIS REPO's forge build
 * artifact (deployCode, not `new`):
 *  - only the owner 0x9a70 can upgrade (0xF8e0 and a stranger are refused);
 *  - after the upgrade, for every id 1..12: a claim that exists answers (0x0, 0) at
 *    every price; a claim that does not exist (redeemed/burned or never minted) reverts
 *    exactly as before; tokenURI, ownerOf, firstExitNotified and the escrow's frozen
 *    royalty snapshot are unchanged; every other observed fact and storage slot is
 *    byte-identical;
 *  - REAL Seaport fills of the listed #11 and #12 credit the controlling NFT's creator
 *    0xF8e0 EXACTLY once each, its live 5% (50,000 and 5,000,000 wei);
 *  - the rollback (upgradeToAndCall(0x9182…, 0x) from 0x9a70) restores the 5% answer
 *    and every observed fact.
 * WHAT IT DOES NOT PROVE: OpenSea's behaviour. Nothing is broadcast.
 *
 * RUN (read-only; the URL comes from YOUR environment):
 *   forge test --match-contract BundleZeroRoyaltyUpgradeForkTest \
 *     --fork-url "$RPC_8453" --fork-block-number 61403135 --threads 1
 * Any fork at or after block 61,400,639 runs it; an older fork SKIPS with the reason.
 */
contract BundleZeroRoyaltyUpgradeForkTest is BundleForkBase {
    address constant OWNER_9A70 = 0x9a704664009d615A90ddDf9345B6b8B2A214cFb2;
    address constant DEPLOYER = 0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF;
    uint256 constant OWNER_9A70_SINCE_BLOCK = 61_400_639;
    uint256 constant LAST_BUNDLE = 12;
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant VALIDATOR = 0xA000027A9B2802E1ddf7000061001e5c005A0000;
    address constant SIGNED_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;
    bytes32 constant CREDITED = keccak256("CreatorRoyaltyCredited(uint256,address,address,uint256)");
    bytes32 constant PROCEEDS = keccak256("ProceedsCredited(uint256,address,address,uint256)");

    NewTradeEscrowV2 escrow = NewTradeEscrowV2(payable(ESCROW));

    struct Claim {
        bool exists;
        bytes royaltyOutcome; // abi.encode(ok, returndata) of royaltyInfo(id, 1 ether)
        address owner;
        bytes32 tokenUriHash;
        bool notified;
        bytes32 snapshotHash;
        uint8 state;
    }

    function _ready() internal returns (bool) {
        if (!forked) return false;
        if (block.number < OWNER_9A70_SINCE_BLOCK) {
            vm.skip(
                true,
                string.concat("needs a fork at or after block 61400639; this fork is at ", vm.toString(block.number))
            );
            return false;
        }
        return true;
    }

    function _royaltyOutcome(uint256 id, uint256 price) internal view returns (bytes memory) {
        (bool ok, bytes memory ret) = PROXY.staticcall(abi.encodeCall(bundle.royaltyInfo, (id, price)));
        return abi.encode(ok, ret);
    }

    function _claim(uint256 id) internal view returns (Claim memory c) {
        (bool ok, bytes memory ret) = PROXY.staticcall(abi.encodeCall(bundle.ownerOf, (id)));
        c.exists = ok;
        if (ok) {
            c.owner = abi.decode(ret, (address));
            c.tokenUriHash = keccak256(bytes(bundle.tokenURI(id)));
        }
        c.royaltyOutcome = _royaltyOutcome(id, 1 ether);
        c.notified = bundle.firstExitNotified(id);
        c.snapshotHash = keccak256(abi.encode(escrow.getRoyaltySnapshot(id)));
        c.state = uint8(escrow.getBundle(id).state);
    }

    function _claims() internal view returns (Claim[] memory cs) {
        cs = new Claim[](LAST_BUNDLE + 2);
        for (uint256 id = 0; id <= LAST_BUNDLE + 1; ++id) {
            cs[id] = _claim(id);
        } // 0 and 13 never minted
    }

    /// Every observed fact except the royalty answer (which this upgrade changes by design).
    function _facts() internal view returns (bytes32) {
        Observed memory o = _observeWithoutRoyalty();
        return keccak256(abi.encode(o));
    }

    function _observeWithoutRoyalty() internal view returns (Observed memory o) {
        o.owner = bundle.owner();
        o.pendingOwner = bundle.pendingOwner();
        o.controller = bundle.controller();
        o.bootstrap = bundle.bootstrap();
        o.seaport = bundle.seaport();
        o.validator = bundle.getTransferValidator();
        (o.validationSelector, o.validationIsView) = bundle.getTransferValidationFunction();
        bytes4[8] memory ids = [
            bytes4(0x2a55205a),
            bytes4(0xad0d7f6c),
            bytes4(0x7f5828d0),
            bytes4(0x80ac58cd),
            bytes4(0x5b5e139f),
            bytes4(0x01ffc9a7),
            bytes4(0x49064906),
            bytes4(0xffffffff)
        ];
        for (uint256 i; i < 8; ++i) {
            o.interfaces[i] = bundle.supportsInterface(ids[i]);
        }
        o.name = bundle.name();
        o.symbol = bundle.symbol();
        o.escrowBalance = bundle.balanceOf(ESCROW);
        for (uint256 i; i < 5; ++i) {
            o.slots[i] = vm.load(PROXY, bytes32(i));
        }
        o.namespaced = [
            vm.load(PROXY, 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00),
            vm.load(PROXY, 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300),
            vm.load(PROXY, 0x237e158222e3e6968b72b9db0d8043aacf074ad9f650f0d1606b4d82ee432c00),
            vm.load(PROXY, 0x80bb2b638cc20bc4d0a60d66940f3ab4a00c1d7b313497ca82fb0b4ab0079300)
        ];
        // The image namespace (renderer, imageBaseURI, externalBaseURI) through its views.
        o.royaltyTo = bundle.imageRenderer();
        o.royaltyAmount = uint256(keccak256(abi.encode(bundle.imageBaseURI(), bundle.externalBaseURI())));
    }

    function _deployNew() internal returns (address impl) {
        impl = deployCode(ARTIFACT);
    }

    function _upgrade(address impl) internal {
        vm.prank(OWNER_9A70);
        bundle.upgradeToAndCall(impl, "");
        assertEq(_implementation(), impl, "the proxy runs the new implementation");
    }

    // ------------------------------------------------------------------ the world

    function test_TheWorld_OwnerIs9a70_ImplementationIs0x9182_RoyaltyIsTheControllers() public {
        if (!_ready()) return;
        assertEq(bundle.owner(), OWNER_9A70, "owner 0x9a70");
        assertEq(bundle.pendingOwner(), address(0));
        assertEq(_implementation(), NON_TRANSFERABLE_IMPLEMENTATION, "0x9182dC37");
        (address to, uint256 amount) = bundle.royaltyInfo(12, 100_000_000);
        assertEq(to, DEPLOYER);
        assertEq(amount, 5_000_000, "5% to 0xF8e0 today (the input OpenSea enforces)");
    }

    // ------------------------------------------------------------------ the new implementation

    function test_NewImplementation_IsLockedAndUups() public {
        if (!_ready()) return;
        address impl = _deployNew();
        assertEq(NewTradeBundle(impl).proxiableUUID(), IMPLEMENTATION_SLOT);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        NewTradeBundle(impl).initialize(address(1), address(1), VALIDATOR, address(this));
        assertEq(NewTradeBundle(impl).owner(), address(0), "the implementation has no owner");
    }

    function test_OnlyTheOwner9a70CanUpgrade() public {
        if (!_ready()) return;
        address impl = _deployNew();
        address[2] memory refused = [DEPLOYER, address(0x5713)];
        for (uint256 i; i < 2; ++i) {
            vm.prank(refused[i]);
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, refused[i]));
            bundle.upgradeToAndCall(impl, "");
        }
        _upgrade(impl);
    }

    // ------------------------------------------------------------------ bundles 1..12

    function test_Upgrade_Bundles1To12_ExistingAnswerZero_MissingRevertAsBefore_RestUnchanged() public {
        if (!_ready()) return;
        Claim[] memory before = _claims();
        bytes32 factsBefore = _facts();
        uint256 existing;
        _upgrade(_deployNew());
        Claim[] memory afterUp = _claims();
        uint256[4] memory prices = [uint256(0), 1, 100_000_000, type(uint256).max];
        for (uint256 id = 0; id <= LAST_BUNDLE + 1; ++id) {
            Claim memory b = before[id];
            Claim memory a = afterUp[id];
            assertEq(a.exists, b.exists, "existence unchanged");
            assertEq(a.owner, b.owner, "ownerOf unchanged");
            assertEq(a.tokenUriHash, b.tokenUriHash, "tokenURI unchanged");
            assertEq(a.notified, b.notified, "firstExitNotified unchanged");
            assertEq(a.snapshotHash, b.snapshotHash, "escrow royalty snapshot unchanged");
            assertEq(a.state, b.state, "escrow state unchanged");
            if (b.exists) {
                ++existing;
                for (uint256 k; k < prices.length; ++k) {
                    (address to, uint256 amount) = bundle.royaltyInfo(id, prices[k]);
                    assertEq(to, address(0), "an existing claim answers recipient 0x0");
                    assertEq(amount, 0, "and amount 0");
                }
            } else {
                assertEq(a.royaltyOutcome, b.royaltyOutcome, "a missing claim reverts exactly as before");
                (bool ok,) = abi.decode(a.royaltyOutcome, (bool, bytes));
                assertFalse(ok, "and it does revert");
            }
            emit log_named_string(
                string.concat("bundle ", vm.toString(id)),
                string.concat(
                    b.exists ? "exists" : "missing",
                    " state ",
                    vm.toString(uint256(b.state)),
                    " royalty-before ",
                    vm.toString(b.royaltyOutcome)
                )
            );
        }
        assertGt(existing, 0, "at least one existing claim was checked");
        assertEq(_facts(), factsBefore, "every other observed fact and slot is byte-identical");
    }

    // ------------------------------------------------------------------ new fills credit exactly once

    function _fill(uint256 id, address buyer) internal returns (uint256 credits, uint256 credited, uint256 proceeds) {
        (OrderParameters memory p,,,,) = escrow.getOrder(id);
        uint256 price = escrow.getBundle(id).price;
        vm.prank(SIGNED_ZONE);
        IStrictRegistryArm(VALIDATOR).beforeAuthorizedTransfer(PROXY, id);
        vm.deal(buyer, price);
        vm.recordLogs();
        vm.prank(buyer);
        assertTrue(ISeaport(SEAPORT).fulfillOrder{value: price}(Order(p, ""), bytes32(0)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != ESCROW) continue;
            if (logs[i].topics[0] == CREDITED) {
                ++credits;
                assertEq(logs[i].topics[1], bytes32(id));
                assertEq(
                    logs[i].topics[2], bytes32(uint256(uint160(DEPLOYER))), "credited to the controller's recipient"
                );
                credited += abi.decode(logs[i].data, (uint256));
            }
            if (logs[i].topics[0] == PROCEEDS) proceeds += abi.decode(logs[i].data, (uint256));
        }
        assertEq(bundle.ownerOf(id), buyer, "issued to the buyer");
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Issued));
    }

    function test_AfterTheUpgrade_RealFillsOf11And12_CreditTheCreatorExactlyOnce() public {
        if (!_ready()) return;
        _upgrade(_deployNew());
        // Arm the strict registry while the SignedZone still has its real code, then stub it.
        uint256 owedBefore = escrow.claimable(DEPLOYER, address(0));
        vm.etch(SIGNED_ZONE, address(new FeeForkZoneStub()).code);

        uint256[2] memory ids = [uint256(11), 12];
        uint256[2] memory royalty = [uint256(50_000), 5_000_000];
        uint256[2] memory sellerNet = [uint256(990_000 - 50_000 - 50_000), 99_000_000 - 5_000_000 - 5_000_000];
        uint256 total;
        for (uint256 i; i < 2; ++i) {
            RoyaltySnapshot memory s = escrow.getRoyaltySnapshot(ids[i]);
            assertEq(s.creator, DEPLOYER, "snapshot creator");
            assertEq(s.creatorNet, royalty[i], "snapshot amount");
            (uint256 credits, uint256 credited, uint256 proceeds) = _fill(ids[i], address(uint160(0xB0B0 + i)));
            assertEq(credits, 1, "exactly one creator credit");
            assertEq(credited, royalty[i], "the controlling NFT's exact royalty");
            assertEq(proceeds, sellerNet[i], "the seller's net");
            (address to, uint256 amount) = bundle.royaltyInfo(ids[i], 1 ether);
            assertEq(to, address(0));
            assertEq(amount, 0, "the issued claim still answers zero");
            total += royalty[i];
        }
        assertEq(escrow.claimable(DEPLOYER, address(0)) - owedBefore, total, "0xF8e0 owed exactly 5,050,000 wei more");
    }

    // ------------------------------------------------------------------ rollback

    function test_Rollback_From9a70_RestoresTheControllersRoyaltyAndEveryFact() public {
        if (!_ready()) return;
        Claim[] memory before = _claims();
        bytes32 factsBefore = _facts();
        _upgrade(_deployNew());
        vm.prank(OWNER_9A70);
        bundle.upgradeToAndCall(NON_TRANSFERABLE_IMPLEMENTATION, "");
        assertEq(_implementation(), NON_TRANSFERABLE_IMPLEMENTATION, "back on 0x9182dC37");
        Claim[] memory back = _claims();
        for (uint256 id = 0; id <= LAST_BUNDLE + 1; ++id) {
            assertEq(
                keccak256(abi.encode(back[id])), keccak256(abi.encode(before[id])), "claim identical after rollback"
            );
        }
        assertEq(_facts(), factsBefore, "facts identical after rollback");
        (address to, uint256 amount) = bundle.royaltyInfo(12, 100_000_000);
        assertEq(to, DEPLOYER);
        assertEq(amount, 5_000_000, "the 5% answer is back");
    }

    // ------------------------------------------------------------------ gas

    function test_Gas_DeployAndUpgrade() public {
        if (!_ready()) return;
        uint256 g = gasleft();
        address impl = _deployNew();
        uint256 deployGas = g - gasleft();
        vm.prank(OWNER_9A70);
        g = gasleft();
        bundle.upgradeToAndCall(impl, "");
        uint256 upgradeGas = g - gasleft();
        emit log_named_uint("implementation runtime bytes", impl.code.length);
        emit log_named_uint("deploy gas (in-test, excludes the 21000 base and calldata)", deployGas);
        emit log_named_uint("upgradeToAndCall gas (in-test, excludes the 21000 base)", upgradeGas);
    }
}
