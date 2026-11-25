// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Mock6551Account is IERC721Receiver, IERC1155Receiver {
    bytes4 private constant VALID_SIGNER_MAGIC = 0x523e3260;

    function token() public view returns (uint256 chainId, address tokenContract, uint256 tokenId) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            extcodecopy(address(), p, 45, 128)
            chainId := mload(add(p, 32))
            tokenContract := mload(add(p, 64))
            tokenId := mload(add(p, 96))
        }
    }

    function owner() public view virtual returns (address) {
        (uint256 c, address t, uint256 i) = token();
        if (c != block.chainid) return address(0);
        return IERC721(t).ownerOf(i);
    }

    function isValidSigner(address signer, bytes calldata) external view virtual returns (bytes4) {
        return signer == owner() ? VALID_SIGNER_MAGIC : bytes4(0);
    }

    /// @dev Lets direct mock implementations stand in for the initialized
    /// Tokenbound proxy in legacy-focused tests.
    function initialize(address) external virtual {}

    function execute(address target, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        virtual
        returns (bytes memory result)
    {
        require(operation == 0 && msg.sender == this.owner(), "AUTH");
        (bool ok, bytes memory out) = target.call{value: value}(data);
        require(ok, "CALL");
        return out;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC721Receiver).interfaceId || id == type(IERC1155Receiver).interfaceId
            || id == type(IERC165).interfaceId;
    }
}

contract Mock6551Implementation is Mock6551Account {}

/// @dev Minimal model of Tokenbound's outer proxy. The ERC-6551 registry points
/// at this template, then initialize selects the approved account logic.
contract MockTokenboundAccountProxy {
    address private immutable initialImplementation;
    address private currentImplementation;

    constructor(address initialImplementation_) {
        initialImplementation = initialImplementation_;
    }

    function initialize(address implementation) external {
        require(implementation == initialImplementation && currentImplementation == address(0), "INITIALIZE");
        currentImplementation = implementation;
    }

    fallback() external payable {
        address implementation = currentImplementation;
        require(implementation != address(0), "UNINITIALIZED");
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract Mock6551RevokedExecutionImplementation is Mock6551Account {
    function execute(address, uint256, bytes calldata, uint8) external payable override returns (bytes memory) {
        revert("REVOKED");
    }
}

contract Mock6551InvalidSignerImplementation is Mock6551Account {
    function isValidSigner(address, bytes calldata) external pure override returns (bytes4) {
        return bytes4(0);
    }
}

contract Mock6551RevertingOwnerImplementation is Mock6551Account {
    function owner() public pure override returns (address) {
        revert("OWNER_REVOKED");
    }
}

contract Mock6551WrongOwnerImplementation is Mock6551Account {
    address private immutable wrongOwner;

    constructor(address wrongOwner_) {
        wrongOwner = wrongOwner_;
    }

    function owner() public view override returns (address) {
        return wrongOwner;
    }

    function isValidSigner(address, bytes calldata) external pure override returns (bytes4) {
        return bytes4(0x523e3260);
    }

    function execute(address target, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        override
        returns (bytes memory result)
    {
        require(operation == 0, "OPERATION");
        (bool ok, bytes memory out) = target.call{value: value}(data);
        require(ok, "CALL");
        return out;
    }
}

contract Mock6551SpoofAccount {
    uint256 private immutable boundChain;
    address private immutable boundToken;
    uint256 private immutable boundId;
    address private immutable reportedOwner;

    constructor(uint256 c, address t, uint256 i, address o) {
        boundChain = c;
        boundToken = t;
        boundId = i;
        reportedOwner = o;
    }

    function token() external view returns (uint256, address, uint256) {
        return (boundChain, boundToken, boundId);
    }

    function owner() external view returns (address) {
        return reportedOwner;
    }

    function isValidSigner(address signer, bytes calldata) external view returns (bytes4) {
        return signer == reportedOwner ? bytes4(0x523e3260) : bytes4(0);
    }
}

contract Mock6551RevertingTokenHolder is IERC721Receiver {
    function token() external pure returns (uint256, address, uint256) {
        revert("TOKEN_REVERTED");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract Mock6551OverrideRegistry {
    address public returnedAccount;

    function setAccount(address account_) external {
        returnedAccount = account_;
    }

    function account(address, bytes32, uint256, address, uint256) external view returns (address) {
        return returnedAccount;
    }

    function createAccount(address, bytes32, uint256, address, uint256) external view returns (address) {
        return returnedAccount;
    }
}

contract Mock6551DivergentRegistry {
    address public immutable predicted;
    address public immutable returned;

    constructor(address predicted_, address returned_) {
        predicted = predicted_;
        returned = returned_;
    }

    function account(address, bytes32, uint256, address, uint256) external view returns (address) {
        return predicted;
    }

    function createAccount(address, bytes32, uint256, address, uint256) external view returns (address) {
        return returned;
    }
}

contract Mock6551WrongTupleRegistry {
    Mock6551Registry private immutable inner;

    constructor() {
        inner = new Mock6551Registry();
    }

    function account(address implementation, bytes32 salt, uint256 chainId, address, uint256 id)
        external
        view
        returns (address)
    {
        return inner.account(implementation, salt, chainId, address(0xBAD), id + 1);
    }

    function createAccount(address implementation, bytes32 salt, uint256 chainId, address, uint256 id)
        external
        returns (address)
    {
        return inner.createAccount(implementation, salt, chainId, address(0xBAD), id + 1);
    }
}

contract ToggleReleaseFailureERC20 is ERC20 {
    bool public failRelease;

    constructor() ERC20("Toggle release", "TR20") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailRelease(bool fail) external {
        failRelease = fail;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (failRelease && from != address(0) && to != address(0)) revert("ERC20_RELEASE");
        super._update(from, to, amount);
    }
}

contract ToggleReleaseFailureERC721 is ERC721 {
    bool public failRelease;

    constructor() ERC721("Toggle release", "TR721") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function setFailRelease(bool fail) external {
        failRelease = fail;
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public override {
        if (failRelease) revert("ERC721_RELEASE");
        super.safeTransferFrom(from, to, id, data);
    }
}

contract ToggleReleaseFailureERC1155 is ERC1155 {
    bool public failRelease;

    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    function setFailRelease(bool fail) external {
        failRelease = fail;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes memory data)
        public
        override
    {
        if (failRelease) revert("ERC1155_RELEASE");
        super.safeTransferFrom(from, to, id, amount, data);
    }
}

contract DoubleCallbackERC1155 is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes memory data)
        public
        override
    {
        super.safeTransferFrom(from, to, id, amount, data);
        if (to.code.length != 0) IERC1155Receiver(to).onERC1155Received(msg.sender, from, id, amount, data);
    }
}

contract BalanceManipulatingERC20 is ERC20 {
    BalanceManipulatingERC20 public victim;
    address public vault;
    uint256 public burnAmount;

    constructor() ERC20("Manipulating", "MAL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(BalanceManipulatingERC20 victim_, address vault_, uint256 amount) external {
        victim = victim_;
        vault = vault_;
        burnAmount = amount;
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool ok) {
        ok = super.transferFrom(from, to, amount);
        if (address(victim) != address(0) && to == vault) victim.burn(vault, burnAmount);
    }
}

contract BalanceManipulatingERC1155 is ERC1155 {
    address public vault;
    uint256 public triggerId;
    uint256 public victimId;
    uint256 public burnAmount;

    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    function arm(address vault_, uint256 triggerId_, uint256 victimId_, uint256 amount) external {
        vault = vault_;
        triggerId = triggerId_;
        victimId = victimId_;
        burnAmount = amount;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes memory data)
        public
        override
    {
        super.safeTransferFrom(from, to, id, amount, data);
        if (to == vault && id == triggerId) _burn(vault, victimId, burnAmount);
    }
}

contract FeeOnTransferERC20 is ERC20 {
    constructor() ERC20("Fee token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from != address(0) && to != address(0) && amount != 0) _burn(to, 1);
    }
}

/// @dev Deliberately non-compliant fee-on-transfer mock: reports the requested
/// callback amount while crediting one unit less so vault balance checks, not
/// callback shape alone, must reject it.
contract FeeOnTransferERC1155 {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external {
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "AUTH");
        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount - 1;
        if (to.code.length != 0) {
            require(
                IERC1155Receiver(to).onERC1155Received(msg.sender, from, id, amount, data)
                    == IERC1155Receiver.onERC1155Received.selector,
                "RECEIVER"
            );
        }
    }
}

contract CallbackFaultERC1155 {
    enum Fault {
        WrongOperator,
        Missing
    }

    Fault public immutable fault;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    constructor(Fault fault_) {
        fault = fault_;
    }

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external {
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "AUTH");
        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;
        if (to.code.length != 0 && fault == Fault.WrongOperator) {
            IERC1155Receiver(to).onERC1155Received(address(0xBAD), from, id, amount, data);
        }
    }
}

contract FinalCallbackDamageERC721 is ERC721 {
    BalanceManipulatingERC20 public immutable victim;
    address public immutable vault;

    constructor(BalanceManipulatingERC20 victim_, address vault_) ERC721("Damaging control", "DMG") {
        victim = victim_;
        vault = vault_;
    }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public override {
        super.safeTransferFrom(from, to, id, data);
        if (to == vault) victim.burn(vault, 1);
    }
}

contract Mock6551Registry {
    function _code(address implementation, bytes32 salt, uint256 chainId, address token, uint256 id)
        private
        pure
        returns (bytes memory)
    {
        bytes memory runtime = abi.encodePacked(
            hex"363d3d373d3d3d363d73",
            implementation,
            hex"5af43d82803e903d91602b57fd5bf3",
            abi.encode(salt, chainId, token, id)
        );
        return abi.encodePacked(hex"3d60ad80600a3d3981f3", runtime);
    }

    function account(address implementation, bytes32 salt, uint256 chainId, address token, uint256 id)
        public
        view
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            salt,
                            keccak256(_code(implementation, salt, chainId, token, id))
                        )
                    )
                )
            )
        );
    }

    function createAccount(address implementation, bytes32 salt, uint256 chainId, address token, uint256 id)
        external
        returns (address a)
    {
        a = account(implementation, salt, chainId, token, id);
        if (a.code.length == 0) {
            bytes memory code = _code(implementation, salt, chainId, token, id);
            assembly ("memory-safe") {
                a := create2(0, add(code, 32), mload(code), salt)
            }
            require(a != address(0), "CREATE2");
        }
    }
}
