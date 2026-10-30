// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// The one message this system sends: prices read on HyperEVM, delivered to Elysium.
///
/// Both sides import this, so the format is written down once and cannot drift apart.
interface IReceiver {
    /// @param perps          HyperCore market indexes, each once, in the order of `prices`
    /// @param prices         one oracle price per market
    /// @param hyperCoreBlock the HyperCore block the prices were read at
    /// @param readAt         the HyperEVM clock when they were read
    function update(
        uint32[] calldata perps,
        uint64[] calldata prices,
        uint64 hyperCoreBlock,
        uint64 readAt
    ) external;
}
