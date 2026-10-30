// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// The few Foundry test functions these tests use, declared by hand so the repo needs
/// no libraries. forge answers calls to this fixed address while tests run.
interface Vm {
    /// Places `code` at `where`, e.g. a fake HyperCore precompile.
    function etch(address where, bytes calldata code) external;

    /// Makes the next call come from `sender`, e.g. the bridge-shifted Beacon address.
    function prank(address sender) external;

    /// Makes the next call pass only if it reverts with exactly `revertData`.
    function expectRevert(bytes calldata revertData) external;

    /// The address the next contract created by `deployer` will get.
    function computeCreateAddress(address deployer, uint256 nonce) external pure returns (address);

    function getNonce(address account) external view returns (uint64);
}

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
