// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {HyperCore} from "./HyperCore.sol";
import {IInbox} from "./IInbox.sol";
import {IReceiver} from "./IReceiver.sol";

/// Lives on HyperEVM. Reads HyperCore prices and sends them to Elysium.
///
/// Elysium accepts messages from HyperEVM and records which contract sent each one.
/// So the Receiver on the other side can insist the prices came from this contract
/// and from nowhere else.
///
/// This contract stores nothing and has no owner. Anyone may call push() and pay for
/// it. Callers choose only *when* prices are sent, never what they say: the values
/// come straight from HyperCore in the same transaction.
contract Beacon {
    IInbox public immutable inbox;
    address public immutable receiver;

    event Pushed(
        uint256 indexed messageNumber, uint64 hyperCoreBlock, uint32[] perps, uint64[] prices
    );

    error NoMarketsGiven();
    error NotEnoughPaid(uint256 needed, uint256 paid);

    constructor(IInbox inbox_, address receiver_) {
        inbox = inbox_;
        receiver = receiver_;
    }

    /// Live prices for `perps`, straight from HyperCore. Call it off-chain to see
    /// exactly what push() would send right now.
    function read(uint32[] calldata perps)
        public
        view
        returns (uint64[] memory prices, uint64 hyperCoreBlock)
    {
        prices = new uint64[](perps.length);
        for (uint256 i = 0; i < perps.length; i++) {
            prices[i] = HyperCore.oraclePx(perps[i]);
        }
        hyperCoreBlock = HyperCore.blockNumber();
    }

    /// Reads the prices and sends them to Elysium, where they land after the bridge delay
    /// (over a minute on testnet).
    ///
    /// List each market once. A repeat makes the Receiver refuse the whole batch.
    ///
    /// `gasLimit` and `maxFeePerGas` buy the Elysium transaction that delivers them.
    /// Neither may be 1: the Inbox treats 1 as a request to revert. Send at least
    /// the fee this works out; whatever is left over is refunded to you on Elysium,
    /// not here (to your shifted address if you are a contract, see Alias.sol).
    function push(uint32[] calldata perps, uint256 gasLimit, uint256 maxFeePerGas)
        external
        payable
        returns (uint256 messageNumber)
    {
        if (perps.length == 0) revert NoMarketsGiven();

        (uint64[] memory prices, uint64 hyperCoreBlock) = read(perps);
        bytes memory message = abi.encodeCall(
            IReceiver.update, (perps, prices, hyperCoreBlock, uint64(block.timestamp))
        );

        uint256 submissionFee = inbox.calculateRetryableSubmissionFee(message.length, block.basefee);
        uint256 needed = submissionFee + gasLimit * maxFeePerGas;
        if (msg.value < needed) revert NotEnoughPaid(needed, msg.value);

        messageNumber = inbox.createRetryableTicket{value: msg.value}(
            receiver, 0, submissionFee, msg.sender, msg.sender, gasLimit, maxFeePerGas, message
        );
        emit Pushed(messageNumber, hyperCoreBlock, perps, prices);
    }
}
