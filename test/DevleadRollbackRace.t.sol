// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {EscrowOptionBUpgradeForkTest} from "./fork/EscrowOptionBUpgradeFork.t.sol";

contract DevleadRollbackRaceTest is EscrowOptionBUpgradeForkTest {
    function test_Review_CheckPasses_NewBListing_Rollback_Fill_PostCheckMissesLoss() public onlyFork {
        _upgrade();
        assertEq(_openBListings().length, 0, "pre-send rollback-check permits");
        (uint256 id,,) = _proofListing();
        uint256 creatorBefore = escrow.claimable(C3F9, address(0));
        _rollback();
        _armAndStub(id);
        _fill(id, P);
        assertEq(_openBListings().length, 0, "post-check incorrectly reports no open B listing");
        assertEq(escrow.claimable(C3F9, address(0)), creatorBefore, "creator credit lost");
        assertEq(escrow.claimable(seller, address(0)), 0.94 ether, "seller gets the creator share");
        _upgrade();
        assertEq(escrow.claimable(C3F9, address(0)), creatorBefore, "forward upgrade cannot repair settled credit");
    }
    function test_Review_DepositedBundleNotFlagged() public onlyFork {
        _upgrade();
        _proofDeposit();
        assertEq(_openBListings().length, 0);
    }
}
