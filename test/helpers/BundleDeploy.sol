// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NewTradeBundle} from "../../src/NewTradeBundle.sol";

/// Deploys the receipt the way the script does: implementation, then an
/// ERC1967Proxy whose constructor runs `initialize` atomically.
library BundleDeploy {
    function deploy(address bootstrap, address seaport, address validator, address owner)
        internal
        returns (NewTradeBundle)
    {
        NewTradeBundle implementation = new NewTradeBundle();
        return NewTradeBundle(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(NewTradeBundle.initialize, (bootstrap, seaport, validator, owner))
                )
            )
        );
    }
}
