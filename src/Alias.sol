// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// The address change a Nitro chain applies to messages from its parent chain.
/// Arbitrum calls this address aliasing.
///
/// A message a HyperEVM contract sends to Elysium arrives from the contract's address
/// plus a fixed offset. This stops a HyperEVM contract from posing as the Elysium
/// contract at the same address. So a check for "did my counterpart send this" must
/// compare against the shifted address.
library Alias {
    uint160 internal constant OFFSET = uint160(0x1111000000000000000000000000000000001111);

    /// How a parent-chain sender appears on this chain.
    function fromParent(address parentSender) internal pure returns (address) {
        unchecked {
            return address(uint160(parentSender) + OFFSET);
        }
    }

    /// The parent-chain address behind a shifted one. The inverse of fromParent.
    function toParent(address shifted) internal pure returns (address) {
        unchecked {
            return address(uint160(shifted) - OFFSET);
        }
    }
}
