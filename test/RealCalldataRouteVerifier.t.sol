// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/TokenMocks.sol";
import {ConsiderationItem, ItemType, OfferItem, OrderParameters, OrderType} from "../src/interfaces/ISeaport.sol";
import {RealCalldataRouteVerifier} from "./helpers/RealCalldataRouteVerifier.sol";

contract MockConduitController {
    mapping(bytes32 => address) public conduits;

    function set(bytes32 key, address conduit) external {
        conduits[key] = conduit;
    }

    function getConduit(bytes32 key) external view returns (address conduit, bool exists) {
        conduit = conduits[key];
        exists = conduit != address(0);
    }
}

contract MockSeaportInformation {
    address public immutable controller;

    constructor(address controller_) {
        controller = controller_;
    }

    function information() external view returns (string memory, bytes32, address) {
        return ("1.6", bytes32(0), controller);
    }
}

contract RouteVerifierWrapper {
    function verify(
        OrderParameters memory order,
        address paymentToken,
        uint256 price,
        uint256 callValue,
        address fulfiller,
        bytes32 actualKey,
        bytes32 expectedKey,
        address seaport
    ) external view returns (address) {
        return RealCalldataRouteVerifier.assertPaymentRoute(
            order, paymentToken, price, callValue, fulfiller, actualKey, expectedKey, seaport
        );
    }
}

contract RealCalldataRouteVerifierTest is Test {
    uint256 private constant PRICE = 1_000_001;
    bytes32 private constant OPENSEA_CONDUIT_KEY = 0x0000007b02230091a7ed01230072f7006a004d60a8d4e71d599b8104250f0000;
    address private constant OPENSEA_CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;
    address private fulfiller = address(0xB0B);
    RouteVerifierWrapper private wrapper;

    function setUp() public {
        wrapper = new RouteVerifierWrapper();
    }

    function test_NativeRouteRequiresExactValueAndNativeConsideration() public view {
        OrderParameters memory order = _order(ItemType.NATIVE, address(0));
        assertEq(
            wrapper.verify(order, address(0), PRICE, PRICE, fulfiller, bytes32(0), bytes32(0), address(0x5EA)),
            address(0)
        );
    }

    function test_NativeRouteRejectsNonOfficialConduitKey() public {
        bytes32 unknownKey = keccak256("unknown native conduit");
        vm.expectRevert(bytes("unsupported fulfiller conduit"));
        wrapper.verify(
            _order(ItemType.NATIVE, address(0)),
            address(0),
            PRICE,
            PRICE,
            fulfiller,
            unknownKey,
            unknownKey,
            address(0x5EA)
        );
    }

    function test_WethNonzeroConduitResolvesAndChecksAllowance() public {
        address baseWeth = 0x4200000000000000000000000000000000000006;
        MockERC20 implementation = new MockERC20("Wrapped Ether", "WETH", 18);
        vm.etch(baseWeth, address(implementation).code);
        MockConduitController controller = new MockConduitController();
        controller.set(OPENSEA_CONDUIT_KEY, OPENSEA_CONDUIT);
        MockSeaportInformation seaport = new MockSeaportInformation(address(controller));
        vm.prank(fulfiller);
        MockERC20(baseWeth).approve(OPENSEA_CONDUIT, PRICE);

        OrderParameters memory order = _order(ItemType.ERC20, baseWeth);
        assertEq(
            wrapper.verify(
                order, baseWeth, PRICE, 0, fulfiller, OPENSEA_CONDUIT_KEY, OPENSEA_CONDUIT_KEY, address(seaport)
            ),
            OPENSEA_CONDUIT
        );
    }

    function test_WethZeroConduitChecksSeaportAllowance() public {
        address baseWeth = 0x4200000000000000000000000000000000000006;
        MockERC20 implementation = new MockERC20("Wrapped Ether", "WETH", 18);
        vm.etch(baseWeth, address(implementation).code);
        MockConduitController controller = new MockConduitController();
        MockSeaportInformation seaport = new MockSeaportInformation(address(controller));
        vm.prank(fulfiller);
        MockERC20(baseWeth).approve(address(seaport), PRICE);

        assertEq(
            wrapper.verify(
                _order(ItemType.ERC20, baseWeth),
                baseWeth,
                PRICE,
                0,
                fulfiller,
                bytes32(0),
                bytes32(0),
                address(seaport)
            ),
            address(seaport)
        );
    }

    function test_WethConduitRouteRejectsMissingAllowance() public {
        address baseWeth = 0x4200000000000000000000000000000000000006;
        MockERC20 implementation = new MockERC20("Wrapped Ether", "WETH", 18);
        vm.etch(baseWeth, address(implementation).code);
        MockConduitController controller = new MockConduitController();
        controller.set(OPENSEA_CONDUIT_KEY, OPENSEA_CONDUIT);
        MockSeaportInformation seaport = new MockSeaportInformation(address(controller));
        vm.expectRevert(bytes("insufficient WETH allowance"));
        wrapper.verify(
            _order(ItemType.ERC20, baseWeth),
            baseWeth,
            PRICE,
            0,
            fulfiller,
            OPENSEA_CONDUIT_KEY,
            OPENSEA_CONDUIT_KEY,
            address(seaport)
        );
    }

    function test_WethRouteRejectsNonOfficialConduit() public {
        address baseWeth = 0x4200000000000000000000000000000000000006;
        MockERC20 implementation = new MockERC20("Wrapped Ether", "WETH", 18);
        vm.etch(baseWeth, address(implementation).code);
        MockConduitController controller = new MockConduitController();
        bytes32 unknownKey = keccak256("unknown conduit");
        controller.set(unknownKey, address(0xC0D017));
        MockSeaportInformation seaport = new MockSeaportInformation(address(controller));
        vm.expectRevert(bytes("unsupported fulfiller conduit"));
        wrapper.verify(
            _order(ItemType.ERC20, baseWeth), baseWeth, PRICE, 0, fulfiller, unknownKey, unknownKey, address(seaport)
        );
    }

    function test_WethRouteRejectsOfficialKeyResolvingToWrongConduit() public {
        address baseWeth = 0x4200000000000000000000000000000000000006;
        MockERC20 implementation = new MockERC20("Wrapped Ether", "WETH", 18);
        vm.etch(baseWeth, address(implementation).code);
        MockConduitController controller = new MockConduitController();
        controller.set(OPENSEA_CONDUIT_KEY, address(0xC0D017));
        MockSeaportInformation seaport = new MockSeaportInformation(address(controller));
        vm.expectRevert(bytes("wrong OpenSea conduit"));
        wrapper.verify(
            _order(ItemType.ERC20, baseWeth),
            baseWeth,
            PRICE,
            0,
            fulfiller,
            OPENSEA_CONDUIT_KEY,
            OPENSEA_CONDUIT_KEY,
            address(seaport)
        );
    }

    function _order(ItemType itemType, address token) private view returns (OrderParameters memory order) {
        OfferItem[] memory offer = new OfferItem[](0);
        ConsiderationItem[] memory consideration = new ConsiderationItem[](2);
        consideration[0] = ConsiderationItem(itemType, token, 0, 925_001, 925_001, payable(address(0xA11CE)));
        consideration[1] = ConsiderationItem(itemType, token, 0, 75_000, 75_000, payable(address(0xC0FFEE)));
        order = OrderParameters(
            address(this),
            address(0),
            offer,
            consideration,
            OrderType.FULL_RESTRICTED,
            0,
            1,
            bytes32(0),
            1,
            bytes32(0),
            2
        );
    }
}
