// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Alias} from "./Alias.sol";
import {IReceiver} from "./IReceiver.sol";

/// Lives on Elysium. Holds the HyperCore prices the Beacon sends from HyperEVM (see
/// Beacon.sol) and serves them to other contracts. It takes updates from the Beacon's
/// bridge address only, so anyone may trigger an update but nobody can change the prices.
///
/// The bridge trip takes over a minute on testnet and is set by the sequencer, so it can
/// differ elsewhere. Every reader must state how old a price it accepts. There is no
/// default, and nothing here returns a stale price quietly.
contract Receiver is IReceiver {
    struct Reading {
        uint64 price;
        uint64 hyperCoreBlock; // which HyperCore block it came from
        uint64 readAt; // HyperEVM clock, when it was read
        uint64 arrivedAt; // Elysium clock, when it landed here
    }

    /// The Beacon as it appears on this chain, already shifted (see Alias.sol).
    address public immutable beacon;

    mapping(uint32 perp => Reading) private readings;

    event Updated(uint32 indexed perp, uint64 price, uint64 hyperCoreBlock);

    error NotTheBeacon(address sender);
    error CountsDoNotMatch(uint256 perps, uint256 prices);
    error NothingForThisMarket(uint32 perp);
    error NotNewerThanStored(uint32 perp, uint64 stored, uint64 offered);
    error ReadInTheFuture(uint64 readAt, uint64 arrivedAt);
    error TooOld(uint32 perp, uint64 age, uint64 maxAge);

    /// @param beaconOnHyperEvm the Beacon's own address on HyperEVM, unshifted
    constructor(address beaconOnHyperEvm) {
        beacon = Alias.fromParent(beaconOnHyperEvm);
    }

    /// Called by the bridge when a Beacon message arrives.
    ///
    /// Reverts if any market's HyperCore block is not newer than the stored one: a
    /// replay, an older push whose failed delivery was rerun later, a second push read
    /// in the same HyperCore block, or a market listed twice. Old data never overwrites
    /// newer data.
    function update(
        uint32[] calldata perps,
        uint64[] calldata prices,
        uint64 hyperCoreBlock,
        uint64 readAt
    ) external {
        if (msg.sender != beacon) revert NotTheBeacon(msg.sender);
        if (perps.length != prices.length) revert CountsDoNotMatch(perps.length, prices.length);
        if (readAt > block.timestamp) revert ReadInTheFuture(readAt, uint64(block.timestamp));

        for (uint256 i = 0; i < perps.length; i++) {
            uint32 perp = perps[i];
            uint64 stored = readings[perp].hyperCoreBlock;
            if (hyperCoreBlock <= stored) revert NotNewerThanStored(perp, stored, hyperCoreBlock);

            readings[perp] = Reading(prices[i], hyperCoreBlock, readAt, uint64(block.timestamp));
            emit Updated(perp, prices[i], hyperCoreBlock);
        }
    }

    /// The price for one market, if it is no older than `maxAge` seconds.
    ///
    /// Age counts from when HyperEVM read the price, so it includes the bridge trip.
    /// Ask for less than the bridge delay and this always reverts.
    function priceOf(uint32 perp, uint64 maxAge) external view returns (uint64 price) {
        Reading memory r = readingOf(perp);
        uint64 age = uint64(block.timestamp) - r.readAt;
        if (age > maxAge) revert TooOld(perp, age, maxAge);
        return r.price;
    }

    /// Everything stored for one market, with no freshness check, for readers that
    /// judge age themselves. Reverts if this market has never been delivered.
    function readingOf(uint32 perp) public view returns (Reading memory r) {
        r = readings[perp];
        if (r.hyperCoreBlock == 0) revert NothingForThisMarket(perp);
    }
}
