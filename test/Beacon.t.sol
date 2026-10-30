// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Alias} from "../src/Alias.sol";
import {Beacon} from "../src/Beacon.sol";
import {HyperCore} from "../src/HyperCore.sol";
import {IInbox} from "../src/IInbox.sol";
import {Receiver} from "../src/Receiver.sol";
import {vm} from "./Vm.sol";

/// Stands in for a HyperCore precompile: answers every read with one fixed number.
contract FakePrecompile {
    uint64 internal immutable value; // immutable, so it survives being copied by etch

    constructor(uint64 value_) {
        value = value_;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(value);
    }
}

/// Stands in for Elysium's Inbox: keeps the message instead of bridging it.
contract FakeInbox is IInbox {
    uint256 internal constant SUBMISSION_FEE = 1000;

    address public to;
    bytes public data;

    function createRetryableTicket(
        address to_,
        uint256,
        uint256 maxSubmissionCost,
        address,
        address,
        uint256,
        uint256,
        bytes calldata data_
    ) external payable returns (uint256) {
        require(maxSubmissionCost == SUBMISSION_FEE, "wrong submission fee");
        to = to_;
        data = data_;
        return 1;
    }

    function calculateRetryableSubmissionFee(uint256, uint256) external pure returns (uint256) {
        return SUBMISSION_FEE;
    }
}

/// One round trip: Beacon reads HyperCore, the message crosses the bridge, Receiver
/// accepts it and serves the price. The bridge step is played by hand: deliver the
/// stored message from the Beacon's shifted address, as Elysium would.
contract BeaconTest {
    uint32 internal constant BTC = 0; // its index on mainnet
    uint64 internal constant BTC_81595_9 = 815959; // BTC prices carry 1 decimal
    uint64 internal constant HYPERCORE_BLOCK = 700_000_000;

    function test_PricesReadOnHyperEvmArriveOnElysium() public {
        vm.etch(HyperCore.ORACLE_PX, address(new FakePrecompile(BTC_81595_9)).code);
        vm.etch(HyperCore.BLOCK_NUMBER, address(new FakePrecompile(HYPERCORE_BLOCK)).code);

        // Each contract needs the other's address, so predict one. Either order works;
        // here the Receiver's is predicted, the README predicts the Beacon's.
        FakeInbox inbox = new FakeInbox();
        address receiverAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        Beacon beacon = new Beacon(inbox, receiverAt);
        Receiver receiver = new Receiver(address(beacon));
        require(address(receiver) == receiverAt, "address prediction is off");

        uint32[] memory perps = new uint32[](1);
        perps[0] = BTC;
        beacon.push{value: 1000 + 100_000 * 2}(perps, 100_000, 2);

        require(inbox.to() == address(receiver), "sent somewhere else");
        bytes memory message = inbox.data(); // read first: prank covers only the next call
        vm.prank(Alias.fromParent(address(beacon)));
        (bool ok,) = address(receiver).call(message);
        require(ok, "Receiver refused the Beacon's message");

        require(receiver.priceOf(BTC, 0) == BTC_81595_9, "wrong price arrived");
        require(receiver.readingOf(BTC).hyperCoreBlock == HYPERCORE_BLOCK, "wrong source block");
    }
}
