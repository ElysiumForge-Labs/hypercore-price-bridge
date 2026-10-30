# Troubleshooting

What goes wrong with a Beacon and Receiver pair, and what to do about it. The
[README](../README.md) explains how the pair works.

## Errors

Every error the contracts raise. `cast` prints the decoded name, such as
`execution reverted: TooOld(0, 7514, 300)`, followed by a `Context:` block with the raw data.

| Error | Raised by | Meaning and fix |
|---|---|---|
| `TooOld(perp, age, maxAge)` | `Receiver.priceOf` | The newest price is older than `maxAge` seconds. Push, then retry after the bridge delay |
| `NothingForThisMarket(perp)` | `Receiver.priceOf`, `readingOf` | This Receiver never received that market. Push it |
| `ReadFailed(precompile)` | `Beacon.read`, `push` | HyperCore rejected the read, usually because the market index does not exist on this network |
| `PriceIsZero(perp)` | `Beacon.read`, `push` | HyperCore returned 0 for that market. Leave it out of the push |
| `NoMarketsGiven()` | `Beacon.push` | `PERPS` was empty |
| `NotEnoughPaid(needed, paid)` | `Beacon.push` | The value sent is below the fee. Use `script/push.sh`, which quotes it |
| `NotNewerThanStored(perp, stored, offered)` | `Receiver.update`, during delivery | The message is not newer than what is held: a late retry, a second push from the same HyperCore block, or a repeated market. Push again |
| `ReadInTheFuture(readAt, arrivedAt)` | `Receiver.update`, during delivery | The HyperEVM read time is later than Elysium's clock. Should not happen given the bridge delay; push again |
| `NotTheBeacon(sender)` | `Receiver.update` | Someone other than the Beacon's aliased address called `update`. Expected; nothing to fix |
| `CountsDoNotMatch(perps, prices)` | `Receiver.update` | Markets and prices differ in length. The Beacon never sends this |

Errors raised during delivery do not show up on HyperEVM: the push succeeds there, and the
delivery fails on Elysium.

## Failure cases

| Event | Result |
|---|---|
| Nobody pushes | Prices age, and `priceOf` reverts with `TooOld` once they pass the caller's limit |
| A push pays too little Elysium gas | The delivery fails and nothing is stored. Anyone can retry it within a week with `redeem` on the `ArbRetryableTx` precompile; pushing again is simpler |
| A failed delivery is retried later | Refused if any of its markets is not newer than the price held |
| Two pushes read the same HyperCore block | The second delivery is refused and its fees are lost. Run one pusher per pair |
| The same market twice in one push | The Receiver refuses the whole push |
| A pusher waits for a favourable price | Possible: the pusher picks the moment, though not the value. Logic that acts on one price, such as liquidations, should allow for it |
| A bug is found in the contracts | Neither contract has an owner or upgrade path. Deploy a new pair and point consumers at the new Receiver |

## Other symptoms

| Symptom | Cause and fix |
|---|---|
| `command not found: cast` | Foundry is not installed or not on `PATH`. See [getfoundry.sh](https://getfoundry.sh/introduction/installation) |
| Push succeeded, price did not change after 2 minutes | The Elysium delivery failed, usually for gas, or the Receiver refused it. Find it on the [Elysium testnet explorer](https://explorer-elysium-testnet.t.conduit.xyz/address/0x12DdFB5e2Bf3544B5BE0Ac5aC9437d3c81fAdF47), then push again |
| `429` or `rate limited` | Public RPC limits. Wait, or use dedicated nodes (see the README) |
| `cast balance` on Elysium stays 0 after `depositEth` | The deposit takes the bridge delay. Check again after 2 minutes |
| `forge create` prints an address other than `$BEACON` | The key sent another HyperEVM transaction in between. Deploy both contracts again |
| Push overpaid, refund missing on HyperEVM | Refunds go to the pusher's address on Elysium, not HyperEVM |
