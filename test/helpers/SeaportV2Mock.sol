// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Order, OrderComponents, OrderParameters} from "../../src/interfaces/ISeaport.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IConduitMock {
    function transferERC721(address token, address from, address to, uint256 id) external;
    function safeTransferERC721(address token, address from, address to, uint256 id) external;
}

contract SeaportV2Mock {
    /// The receipt must see the CONDUIT as operator, exactly as it would on
    /// chain when the order carries a non-zero conduit key.
    address constant OPENSEA_CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;

    uint256 public counter;
    bool public rejectValidation;
    mapping(bytes32 => bool) public validated;

    // Cancellation and order status, added for the legacy-listing repair path.
    // MOCK BEHAVIOUR, not Seaport: this models only the rules the repair relies
    // on - offerer-only cancellation, and a status triple the repair reads back.
    mapping(bytes32 => bool) public cancelledOrders;
    mapping(bytes32 => uint256) public filledAmount;
    bool public rejectCancel;

    function setRejectCancel(bool reject) external {
        rejectCancel = reject;
    }

    /// @dev Test hook: pretend a buyer partially or fully took the order.
    function setFilled(bytes32 orderHash, uint256 amount) external {
        filledAmount[orderHash] = amount;
    }

    /// @dev Test hook: pretend the order was already cancelled out of band.
    function setCancelled(bytes32 orderHash, bool value) external {
        cancelledOrders[orderHash] = value;
    }

    /// @dev Test hook: drop an order's validated flag without cancelling it.
    function setValidated(bytes32 orderHash, bool value) external {
        validated[orderHash] = value;
    }

    /// @dev Only the offerer may cancel, which is why the escrow proxy has to be
    /// the one calling: a seller signature cannot stand in for it.
    function cancel(OrderComponents[] calldata orders) external returns (bool) {
        if (rejectCancel) return false;
        for (uint256 i; i < orders.length; ++i) {
            require(orders[i].offerer == msg.sender, "OFFERER_ONLY");
            bytes32 h = keccak256(abi.encode(orders[i]));
            cancelledOrders[h] = true;
            validated[h] = false;
        }
        return true;
    }

    function getOrderStatus(bytes32 orderHash)
        external
        view
        returns (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize)
    {
        return (validated[orderHash], cancelledOrders[orderHash], filledAmount[orderHash], 1);
    }

    function setCounter(uint256 counter_) external {
        counter = counter_;
    }

    function setRejectValidation(bool reject) external {
        rejectValidation = reject;
    }

    /// @notice Models the ERC-721C validator: only an authorized marketplace
    /// transfer may move a receipt between holders.
    /// Mirrors the live StrictAuthorizedTransferSecurityRegistry closely enough
    /// to be meaningful: the CONDUIT is the operator a real sale presents, so a
    /// mock that only authorized Seaport would test a path the real flow never
    /// takes. This is still a mock - it does NOT prove SignedZone authorization.
    function validateTransfer(address caller, address, address, uint256) external view {
        require(caller == address(this) || caller == OPENSEA_CONDUIT, "TRANSFER_NOT_AUTHORIZED");
    }

    function transferReceipt(address receipt, address from, address to, uint256 id) external {
        IConduitMock(OPENSEA_CONDUIT).transferERC721(receipt, from, to, id);
    }

    function safeTransferReceipt(address receipt, address from, address to, uint256 id) external {
        IConduitMock(OPENSEA_CONDUIT).safeTransferERC721(receipt, from, to, id);
    }

    /// Seaport's EIP-712 domain separator. Settable so a test can move it and
    /// prove the escrow's 1271 digest stops validating when the domain changes.
    bytes32 public domainSeparator = keccak256("SEAPORT_V2_MOCK_DOMAIN");

    function setDomainSeparator(bytes32 value) external {
        domainSeparator = value;
    }

    function information() external view returns (string memory, bytes32, address) {
        return ("1.6", domainSeparator, address(0));
    }

    function getCounter(address) external view returns (uint256) {
        return counter;
    }

    function getOrderHash(OrderComponents calldata c) external pure returns (bytes32) {
        return keccak256(abi.encode(c));
    }

    function validate(Order[] calldata orders) external returns (bool) {
        if (rejectValidation) return false;
        for (uint256 i; i < orders.length; ++i) {
            require(orders[i].parameters.offerer == msg.sender, "OFFERER_ONLY");
            require(orders[i].signature.length == 0, "SIGNATURE");
            OrderParameters calldata p = orders[i].parameters;
            OrderComponents memory c = OrderComponents(
                p.offerer,
                p.zone,
                p.offer,
                p.consideration,
                p.orderType,
                p.startTime,
                p.endTime,
                p.zoneHash,
                p.salt,
                p.conduitKey,
                counter
            );
            validated[keccak256(abi.encode(c))] = true;
        }
        return true;
    }

    function fill(OrderParameters calldata p, address recipient) external {
        require(block.timestamp < p.endTime, "EXPIRED");
        OrderComponents memory c = OrderComponents(
            p.offerer,
            p.zone,
            p.offer,
            p.consideration,
            p.orderType,
            p.startTime,
            p.endTime,
            p.zoneHash,
            p.salt,
            p.conduitKey,
            counter
        );
        bytes32 h = keccak256(abi.encode(c));
        require(validated[h], "NOT_VALIDATED");
        // Seaport writes order status BEFORE transferring the offer item
        // (_updateStatus precedes _transferEach), which is exactly why the
        // escrow can read a fully-filled status inside the first-exit callback.
        // A mock that filled after transferring would make that check untestable.
        filledAmount[h] = 1;
        IConduitMock(OPENSEA_CONDUIT).transferERC721(p.offer[0].token, p.offerer, recipient, p.offer[0].identifierOrCriteria);
    }

    /// Models settlement failing AFTER the offer item moved: same ordering as
    /// `fill` - status written, then transfer - then a revert standing in for a
    /// consideration transfer that could not be paid. The ordering matters: if
    /// this reverted before writing status, the escrow's first-exit callback
    /// would reject the fill on its own and the rollback under test would never
    /// be the thing that rolled it back.
    /**
     * `fill` plus REAL consideration transfers, pulled from `payer`.
     *
     * Deliberately a separate entry point rather than a conditional inside
     * `fill`: a mock that paid only when the payer happened to have balance and
     * approval would quietly stop testing settlement the moment a fixture
     * changed. Tests that assert on payout must ask for payment explicitly.
     *
     * ERC20 only - native consideration is covered by the fork matrix.
     */
    function fillAndPay(OrderParameters calldata p, address recipient, address payer) external {
        this.fill(p, recipient);
        for (uint256 i; i < p.consideration.length; ++i) {
            IERC20(p.consideration[i].token).transferFrom(
                payer, p.consideration[i].recipient, p.consideration[i].startAmount
            );
        }
    }

    /**
     * `fill` plus REAL native consideration transfers, paid from msg.value and
     * sent by THIS contract - which is what the escrow's and the royalty
     * receiver's `receive()` (Seaport-only) actually see on chain. Same ordering
     * as Seaport: offer item first, consideration after, so a first-exit
     * callback that tried to sweep would find nothing yet.
     */
    function fillAndPayNative(OrderParameters calldata p, address recipient) external payable {
        this.fill(p, recipient);
        uint256 total;
        for (uint256 i; i < p.consideration.length; ++i) {
            uint256 amount = p.consideration[i].startAmount;
            total += amount;
            (bool ok,) = p.consideration[i].recipient.call{value: amount}("");
            require(ok, "NATIVE_PAYMENT_FAILED");
        }
        require(total == msg.value, "WRONG_VALUE");
    }

    function fillAndRevert(OrderParameters calldata p, address recipient) external {
        OrderComponents memory c = OrderComponents(
            p.offerer,
            p.zone,
            p.offer,
            p.consideration,
            p.orderType,
            p.startTime,
            p.endTime,
            p.zoneHash,
            p.salt,
            p.conduitKey,
            counter
        );
        bytes32 h = keccak256(abi.encode(c));
        require(validated[h], "NOT_VALIDATED");
        filledAmount[h] = 1;
        IConduitMock(OPENSEA_CONDUIT).transferERC721(p.offer[0].token, p.offerer, recipient, p.offer[0].identifierOrCriteria);
        revert("PAYMENT_FAILED");
    }
}
