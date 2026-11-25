// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ItemType, OrderParameters} from "../../src/interfaces/ISeaport.sol";

interface ISeaportInformation {
    function information()
        external
        view
        returns (string memory version, bytes32 domainSeparator, address conduitController);
}

interface IConduitController {
    function getConduit(bytes32 conduitKey) external view returns (address conduit, bool exists);
}

/// @notice Shared route checks used by the real-calldata fork replay and by
/// local native/WETH tests. This does not emulate Seaport or SignedZone.
library RealCalldataRouteVerifier {
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    bytes32 internal constant OPENSEA_CONDUIT_KEY = 0x0000007b02230091a7ed01230072f7006a004d60a8d4e71d599b8104250f0000;
    address internal constant OPENSEA_CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;

    function assertPaymentRoute(
        OrderParameters memory order,
        address paymentToken,
        uint256 price,
        uint256 callValue,
        address fulfiller,
        bytes32 actualFulfillerConduitKey,
        bytes32 expectedFulfillerConduitKey,
        address seaport
    ) internal view returns (address approvalTarget) {
        require(actualFulfillerConduitKey == expectedFulfillerConduitKey, "unexpected fulfiller conduit");
        require(
            actualFulfillerConduitKey == bytes32(0) || actualFulfillerConduitKey == OPENSEA_CONDUIT_KEY,
            "unsupported fulfiller conduit"
        );
        require(order.consideration.length != 0, "empty consideration");
        uint256 total;
        for (uint256 i; i < order.consideration.length; ++i) {
            require(order.consideration[i].token == paymentToken, "mixed consideration token");
            require(order.consideration[i].startAmount == order.consideration[i].endAmount, "dynamic consideration");
            total += order.consideration[i].startAmount;
            if (paymentToken == address(0)) {
                require(order.consideration[i].itemType == ItemType.NATIVE, "native item type mismatch");
            } else {
                require(order.consideration[i].itemType == ItemType.ERC20, "erc20 item type mismatch");
            }
        }
        require(total == price, "consideration total mismatch");

        if (paymentToken == address(0)) {
            require(callValue == price, "native call value mismatch");
            return address(0);
        }

        require(paymentToken == BASE_WETH, "erc20 route is not Base WETH");
        require(callValue == 0, "WETH route must not send ETH");
        approvalTarget = seaport;
        if (actualFulfillerConduitKey != bytes32(0)) {
            (,, address controller) = ISeaportInformation(seaport).information();
            (address conduit, bool exists) = IConduitController(controller).getConduit(actualFulfillerConduitKey);
            require(exists && conduit == OPENSEA_CONDUIT, "wrong OpenSea conduit");
            approvalTarget = conduit;
        }
        require(IERC20(paymentToken).allowance(fulfiller, approvalTarget) >= price, "insufficient WETH allowance");
    }
}
