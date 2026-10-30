// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Alias} from "../src/Alias.sol";
import {Receiver} from "../src/Receiver.sol";
import {vm} from "./Vm.sol";

/// The Receiver trusts one shifted address. Deploying it with this test contract's own
/// unshifted address makes the trusted address exactly this contract, so these tests
/// stand in for the bridge by calling it directly.
contract ReceiverTest {
    Receiver internal receiver;

    uint32 internal constant BTC = 0; // its index on mainnet
    uint64 internal constant BTC_81595_9 = 815959; // BTC prices carry 1 decimal

    function setUp() public {
        receiver = new Receiver(Alias.toParent(address(this)));
    }

    function test_StoresAndServesAPrice() public {
        send(BTC, BTC_81595_9, 100, uint64(block.timestamp));

        require(receiver.priceOf(BTC, 0) == BTC_81595_9, "wrong price");
        require(receiver.readingOf(BTC).hyperCoreBlock == 100, "wrong source block");
    }

    /// The whole security model: only the Beacon, as shifted by the bridge, may write.
    function test_RejectsAnyoneButTheBeacon() public {
        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Receiver.NotTheBeacon.selector, stranger));
        send(BTC, 1, 1, uint64(block.timestamp));
    }

    /// A delayed or replayed message must not overwrite newer data.
    function test_RejectsAPriceNoNewerThanStored() public {
        send(BTC, 100, 50, uint64(block.timestamp));

        vm.expectRevert(abi.encodeWithSelector(Receiver.NotNewerThanStored.selector, BTC, 50, 50));
        send(BTC, 999, 50, uint64(block.timestamp));

        require(receiver.priceOf(BTC, 0) == 100, "stored price was overwritten");
    }

    /// readAt of 0 is the epoch, so the price is as old as the chain clock.
    function test_RefusesToServeAStalePrice() public {
        send(BTC, 100, 1, 0);

        uint64 age = uint64(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(Receiver.TooOld.selector, BTC, age, age - 1));
        receiver.priceOf(BTC, age - 1);
    }

    function send(uint32 perp, uint64 price, uint64 hyperCoreBlock, uint64 readAt) internal {
        uint32[] memory perps = new uint32[](1);
        uint64[] memory prices = new uint64[](1);
        perps[0] = perp;
        prices[0] = price;
        receiver.update(perps, prices, hyperCoreBlock, readAt);
    }
}
