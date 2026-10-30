// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// Reading Hyperliquid's exchange from a contract on HyperEVM.
///
/// HyperCore is the exchange itself: the order books, and the prices it trades at.
/// HyperEVM is the smart-contract chain beside it. A contract on HyperEVM reads
/// HyperCore through precompiles, which are built-in functions at fixed addresses.
///
/// Elysium has no such functions, which is why these prices must be read here and
/// carried across. See Beacon.sol.
///
/// Nothing here returns a default value. A failed read reverts, because a silent zero
/// cannot be told apart from a real price of zero.
library HyperCore {
    /// The price HyperCore itself uses for a perpetual market.
    address internal constant ORACLE_PX = address(0x807);

    /// The height of HyperCore's own chain.
    address internal constant BLOCK_NUMBER = address(0x809);

    error ReadFailed(address precompile);
    error PriceIsZero(uint32 perp);

    /// Price of one perpetual market, as a fixed-point integer.
    /// `perp` is the market's index in HyperCore's market list. On mainnet 0 is BTC and
    /// 1 is ETH; testnet has its own list.
    ///
    /// Divide by 10^(6 - szDecimals) for the real price, where szDecimals is the market's
    /// size precision from Hyperliquid's market list. BTC's is 5, so 815959 is 81,595.9.
    function oraclePx(uint32 perp) internal view returns (uint64 price) {
        price = abi.decode(read(ORACLE_PX, abi.encode(perp)), (uint64));
        if (price == 0) revert PriceIsZero(perp);
    }

    /// The HyperCore block the prices were read at. The Receiver uses it to refuse
    /// anything older than what it holds.
    function blockNumber() internal view returns (uint64) {
        return abi.decode(read(BLOCK_NUMBER, ""), (uint64));
    }

    function read(address precompile, bytes memory input)
        private
        view
        returns (bytes memory output)
    {
        bool ok;
        (ok, output) = precompile.staticcall(input);
        if (!ok || output.length != 32) revert ReadFailed(precompile);
    }
}
