// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {V2BundleEscrowTest} from "./V2BundleEscrow.t.sol";
import {Payout, BundleState} from "../src/NewTradeV2Types.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OrderParameters} from "../src/interfaces/ISeaport.sol";
import {SeaportV2Mock} from "./helpers/SeaportV2Mock.sol";

/// zero-royalty-wrapper (item 62(3)): the Bundle answers ERC-2981 with (0x0, 0) for
/// every existing claim and reverts for one that does not exist; the escrow keeps
/// quoting the CONTROLLING NFT and credits its creator exactly once at the first exit.
contract BundleZeroRoyaltyTest is V2BundleEscrowTest {
    address creator = address(0xCAFE);
    bytes32 constant CREDITED = keccak256("CreatorRoyaltyCredited(uint256,address,address,uint256)");

    function _royalty(address recipient, uint256 amount) internal {
        vm.mockCall(
            address(control), abi.encodeCall(IERC165.supportsInterface, (type(IERC2981).interfaceId)), abi.encode(true)
        );
        vm.mockCall(address(control), abi.encodeCall(IERC2981.royaltyInfo, (1, PRICE)), abi.encode(recipient, amount));
    }

    function _listWhole(uint256 id) internal returns (OrderParameters memory p) {
        Payout[] memory ps = new Payout[](1);
        ps[0] = Payout(payable(address(escrow)), PRICE);
        vm.prank(seller);
        escrow.list(id, address(erc20), PRICE, deadline, 1000, ps);
        (p,,,,) = escrow.getOrder(id);
    }

    function _assertZero(uint256 id) internal view {
        uint256[4] memory prices = [uint256(0), 1, PRICE, type(uint256).max];
        for (uint256 i; i < prices.length; ++i) {
            (address r, uint256 a) = receipt.royaltyInfo(id, prices[i]);
            assertEq(r, address(0), "recipient 0x0");
            assertEq(a, 0, "amount 0");
        }
    }

    function test_ExistingClaim_ZeroAtEveryPrice_WhileDepositedListedAndIssued() public {
        _royalty(creator, 0.1 ether);
        uint256 id = deposit(); // the claim is minted to the escrow at deposit
        _assertZero(id);
        OrderParameters memory p = _listWhole(id);
        _assertZero(id);
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Issued));
        _assertZero(id);
    }

    function test_NonexistentClaim_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 777));
        receipt.royaltyInfo(777, PRICE);
    }

    function test_RedeemedClaim_RevertsLikeANonexistentOne() public {
        _royalty(creator, 0.1 ether);
        uint256 id = deposit();
        OrderParameters memory p = _listWhole(id);
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        vm.prank(buyer);
        escrow.redeemToFreshAccount(id, bytes32(uint256(123)));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        receipt.royaltyInfo(id, PRICE);
    }

    function test_StillAdvertisesErc2981() public view {
        assertTrue(receipt.supportsInterface(type(IERC2981).interfaceId));
    }

    function test_NewFill_CreditsTheControllingNftsCreatorExactlyOnce() public {
        _royalty(creator, 0.1 ether);
        uint256 id = deposit();
        (, uint256 fee, address quoted, uint256 quotedAmount) = escrow.quotePrimaryFees(id, PRICE);
        assertEq(quoted, creator, "the escrow quotes the controller's recipient");
        assertEq(quotedAmount, 0.1 ether, "and its amount");
        OrderParameters memory p = _listWhole(id);
        assertEq(escrow.getRoyaltySnapshot(id).creator, creator, "the escrow froze the controller's recipient");
        assertEq(escrow.getRoyaltySnapshot(id).creatorNet, 0.1 ether, "and its amount");

        // A paying fill: the buyer's tokens reach the escrow item, as on Seaport.
        erc20.mint(buyer, PRICE);
        vm.prank(buyer);
        erc20.approve(SEAPORT, PRICE);
        vm.recordLogs();
        SeaportV2Mock(SEAPORT).fillAndPay(p, buyer, buyer);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 credits;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(escrow) && logs[i].topics[0] == CREDITED) {
                ++credits;
                assertEq(logs[i].topics[1], bytes32(id));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(creator))));
                assertEq(abi.decode(logs[i].data, (uint256)), 0.1 ether);
            }
        }
        assertEq(credits, 1, "exactly one creator credit");
        assertEq(escrow.claimable(creator, address(erc20)), 0.1 ether, "creator owed its exact royalty");
        assertEq(escrow.claimable(seller, address(erc20)), PRICE - 0.1 ether - fee, "seller owed the rest");

        // Redemption burns the claim; it neither credits again nor changes the ledger.
        vm.recordLogs();
        vm.prank(buyer);
        escrow.redeemToFreshAccount(id, bytes32(uint256(7)));
        logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != CREDITED, "no second credit");
        }
        assertEq(escrow.claimable(creator, address(erc20)), 0.1 ether, "still exactly one royalty");

        // The creator withdraws it once.
        uint256 before = erc20.balanceOf(creator);
        vm.prank(creator);
        escrow.withdraw(address(erc20));
        assertEq(erc20.balanceOf(creator) - before, 0.1 ether);
        assertEq(escrow.claimable(creator, address(erc20)), 0);
    }
}
