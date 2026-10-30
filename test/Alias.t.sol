// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Alias} from "../src/Alias.sol";

contract AliasTest {
    /// A real pair seen on HyperEVM testnet: an ERC-20 gateway (stock Arbitrum code) sends
    /// retryables to Elysium, and the bridge records the second address as their sender.
    address internal constant GATEWAY_ON_HYPEREVM = 0x08922Faa84aC2a54aa3cFD3725b03ca256F52Da2;
    address internal constant AS_SEEN_ON_ELYSIUM = 0x19A32fAA84Ac2A54AA3Cfd3725B03ca256F53Eb3;

    function test_MatchesARealBridgeMessage() public pure {
        require(Alias.fromParent(GATEWAY_ON_HYPEREVM) == AS_SEEN_ON_ELYSIUM, "wrong shift");
        require(Alias.toParent(AS_SEEN_ON_ELYSIUM) == GATEWAY_ON_HYPEREVM, "wrong unshift");
    }
}
