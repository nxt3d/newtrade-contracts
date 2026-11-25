// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice OpenSea-compatible ERC-721C creator-token surface.
interface ICreatorToken {
    event TransferValidatorUpdated(address oldValidator, address newValidator);

    function getTransferValidator() external view returns (address validator);
    function getTransferValidationFunction() external view returns (bytes4 functionSignature, bool isViewFunction);
    function setTransferValidator(address validator) external;
}

/// @notice ERC-721 token-specific transfer check used by creator-token validators.
interface ITransferValidator {
    function validateTransfer(address caller, address from, address to, uint256 tokenId) external view;
}
