// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IERC6551Registry {
    function createAccount(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external returns (address account);
    function account(address implementation, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external view returns (address account);
}

interface IERC6551Account {
    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);
    function isValidSigner(address signer, bytes calldata context) external view returns (bytes4 magicValue);
}

/// @notice Supported-adapter extension. owner() is not part of ERC-6551.
interface IERC6551OwnerAccount {
    function owner() external view returns (address);
}

interface IERC6551ExecutableAccount is IERC6551Account {
    function execute(address target, uint256 value, bytes calldata data, uint8 operation)
        external payable returns (bytes memory result);
}

/// @notice Tokenbound's outer account proxy, which is created by the ERC-6551
/// registry and then initialized to the approved account logic.
interface ITokenboundAccountProxy {
    function initialize(address implementation) external;
}
