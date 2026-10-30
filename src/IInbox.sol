// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// Elysium's Inbox, which lives on HyperEVM. Only the two functions the Beacon calls.
///
/// createRetryableTicket hands Elysium a message, which Elysium later runs as a transaction
/// from the sending contract's shifted address (see Alias.sol). The caller pays Elysium's
/// gas here, in the same transaction.
/// It returns the message's number in Elysium's delayed inbox, not the ticket id that
/// Elysium gives the delivery.
///
/// Elysium's gas coin is HYPE, which is also HyperEVM's own coin, so the payment is
/// plain msg.value. Chains whose gas is an ERC-20 token use a different signature.
interface IInbox {
    function createRetryableTicket(
        address to,
        uint256 l2CallValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        bytes calldata data
    ) external payable returns (uint256 messageNumber);

    /// What Elysium charges just to accept a message of `dataLength` bytes.
    function calculateRetryableSubmissionFee(uint256 dataLength, uint256 baseFee)
        external
        view
        returns (uint256);
}
