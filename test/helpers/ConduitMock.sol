// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * Minimal stand-in for the OpenSea conduit, etched at its real address.
 *
 * It exists so local tests reproduce the operator the receipt ACTUALLY sees:
 * with a non-zero conduit key Seaport moves the offer item through
 * `conduit.execute`, so the receipt's validator and the escrow's first-exit
 * callback observe the CONDUIT, not Seaport. A mock that transfers as Seaport
 * would test a path the real flow never takes.
 */
contract ConduitMock {
    function transferERC721(address token, address from, address to, uint256 id) external {
        IERC721(token).transferFrom(from, to, id);
    }

    function safeTransferERC721(address token, address from, address to, uint256 id) external {
        IERC721(token).safeTransferFrom(from, to, id);
    }
}
