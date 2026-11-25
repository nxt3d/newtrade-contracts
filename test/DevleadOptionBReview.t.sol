// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {V2OptionBTest} from "./V2OptionB.t.sol";
import {EscrowOptionBUpgradeForkTest} from "./fork/EscrowOptionBUpgradeFork.t.sol";
import {RoyaltySnapshot} from "../src/NewTradeV2Types.sol";
import {OrderParameters} from "../src/interfaces/ISeaport.sol";

contract DevleadOptionBSnapshotTest is V2OptionBTest {
    function test_Review_ZeroRoyaltyAllowsAnItemToTheDeclaredCreator() public live {
        _royaltyBps(C3F9, 0);
        (, OrderParameters memory p) = _list(_two(0.99 ether, C3F9, 0.01 ether), 0);
        uint256 beforeBalance = erc20.balanceOf(C3F9);
        _fill(p);
        assertEq(erc20.balanceOf(C3F9) - beforeBalance, 0.01 ether);
        assertEq(escrow.claimable(C3F9, address(erc20)), 0);
    }
    function test_Review_SnapshotAndSettlementSurviveRoyaltyAndFeeChanges() public live {
        _royaltyBps(C3F9, 250);
        (uint256 id, OrderParameters memory p) = _list(_bShape(), 250);
        bytes32 beforeHash = keccak256(abi.encode(escrow.getRoyaltySnapshot(id)));
        _royaltyBps(address(0xDEAD), 1000);
        escrow.setProtocolFeeBps(1000);
        assertEq(keccak256(abi.encode(escrow.getRoyaltySnapshot(id))), beforeHash);
        _fill(p);
        assertEq(escrow.claimable(C3F9, address(erc20)), 0.025 ether);
        assertEq(escrow.claimable(seller, address(erc20)), 0.915 ether);
        assertEq(escrow.claimable(address(0xDEAD), address(erc20)), 0);
        assertEq(escrow.totalOwed(address(erc20)), 0.94 ether);
    }
}

contract DevleadOptionBRollbackTest is EscrowOptionBUpgradeForkTest {
    function test_Review_RollbackWithAnUnfilledBListingLosesCreatorRoyalty() public onlyFork {
        _upgrade();
        (uint256 id,,) = _proofListing();
        uint256 beforeCreator = escrow.claimable(C3F9, address(0));
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(CURRENT_IMPL, "");
        _armAndStub(id);
        _fill(id, P);
        // Demonstrates the unsafe rollback: old code ignores the B royalty snapshot.
        assertEq(escrow.claimable(C3F9, address(0)), beforeCreator);
        assertEq(escrow.claimable(seller, address(0)), 0.94 ether);
    }
}
