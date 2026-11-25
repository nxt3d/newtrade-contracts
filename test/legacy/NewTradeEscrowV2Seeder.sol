// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NewTradeEscrowV2Storage} from "../../src/NewTradeEscrowV2Storage.sol";

/// @notice A ONE-SHOT hop that exists only inside NewTradeEscrowV2's
/// fee-from-proceeds upgrade (escrow-fee-from-proceeds-sep25). It seeds the owed
/// ledger from the ledger itself and upgrades on to the final implementation in
/// the SAME call, so no block ever sees the proxy on this contract or a
/// `_totalOwed` that does not equal what the escrow owes.
///
/// The one user transaction, on the escrow proxy, from an UPGRADER_ROLE holder:
///   upgradeToAndCall(seeder, abi.encodeCall(seedAndUpgrade, (finalImpl, tokens, accounts)))
/// The current implementation authorizes that hop (UPGRADER_ROLE, not locked),
/// then delegatecalls `seedAndUpgrade` here with the caller preserved.
///
/// It shares NewTradeEscrowV2's storage through NewTradeEscrowV2Storage (the
/// OpenZeppelin parents are namespaced), so it reads the same `_claimable` and
/// writes the same `_totalOwed`. It never writes `_claimable`.
contract NewTradeEscrowV2Seeder is Initializable, UUPSUpgradeable, AccessControlUpgradeable, NewTradeEscrowV2Storage {
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    event TotalOwedSeeded(address indexed token, uint256 total, uint256 accounts);

    /// The listed accounts' claimable does not equal the escrow's balance of
    /// `token` (an account omitted, one listed twice, or stray funds present),
    /// or the ledger for `token` was already seeded.
    error SeedMismatch(address token, uint256 sum, uint256 balance);
    /// `finalImpl` is not a UUPS implementation, or the hop did not land on it.
    error BadFinalImplementation(address finalImpl);
    /// This contract is never a resting implementation: nothing may upgrade from it.
    error SeederOnly();

    constructor() {
        _disableInitializers();
    }

    /// @notice Seeds `_totalOwed` for every token to the sum of the listed accounts' claimable
    /// token, requiring that sum to EQUAL the escrow's balance exactly, then
    /// upgrades the proxy to `finalImpl`. Runs once: `reinitializer(2)`.
    function seedAndUpgrade(address finalImpl, address[] calldata tokens, address[] calldata accounts)
        external
        reinitializer(2)
    {
        if (!hasRole(UPGRADER_ROLE, msg.sender)) revert AccessControlUnauthorizedAccount(msg.sender, UPGRADER_ROLE);
        for (uint256 t; t < tokens.length; ++t) {
            address token = tokens[t];
            uint256 sum;
            for (uint256 a; a < accounts.length; ++a) {
                sum += _claimable[accounts[a]][token];
            }
            uint256 balance = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
            if (_totalOwed[token] != 0 || sum != balance) revert SeedMismatch(token, sum, balance);
            _totalOwed[token] = sum;
            emit TotalOwedSeeded(token, sum, accounts.length);
        }
        // The second hop, with the same UUPS check UUPSUpgradeable applies to the first.
        if (finalImpl.code.length == 0 || IERC1822Proxiable(finalImpl).proxiableUUID() != ERC1967Utils.IMPLEMENTATION_SLOT)
        {
            revert BadFinalImplementation(finalImpl);
        }
        ERC1967Utils.upgradeToAndCall(finalImpl, "");
        if (ERC1967Utils.getImplementation() != finalImpl) revert BadFinalImplementation(finalImpl);
    }

    function _authorizeUpgrade(address) internal pure override {
        revert SeederOnly();
    }
}
