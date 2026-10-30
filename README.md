# hypercore-price-bridge

Bridge HyperCore oracle prices from HyperEVM → Elysium via the delayed inbox.

Part of [ElysiumForge Labs](https://github.com/ElysiumForge-Labs).

> **Experimental.** A testnet proof of concept, not audited. Do not use it in production.

HyperEVM contracts can read HyperCore's oracle prices. Elysium contracts cannot: Elysium runs
Arbitrum Nitro, and Nitro has no HyperCore precompiles. This repository copies those prices
across the bridge that already connects the two chains.

One contract lives on each side. `Beacon` on HyperEVM reads the prices and posts them into
Elysium's delayed inbox. About a minute later, Elysium runs that message and `Receiver` stores
the prices. Any Elysium contract then calls `priceOf`.

A working pair is live on testnet. The [quick start](#quick-start) reads it with no key and no
funds. There is no mainnet deployment.

## Contents

- [The idea in one pass](#the-idea-in-one-pass)
- [Why a bridge is required](#why-a-bridge-is-required)
- [What gets stored](#what-gets-stored)
- [Who is allowed to write a price](#who-is-allowed-to-write-a-price)
- [What this is a good fit for](#what-this-is-a-good-fit-for)
- [Repository map](#repository-map)
- [Contract reference](#contract-reference)
- [Reading a raw price as dollars](#reading-a-raw-price-as-dollars)
- [Quick start](#quick-start)
- [Call it from a contract](#call-it-from-a-contract)
- [What a push costs](#what-a-push-costs)
- [Deploy your own pair](#deploy-your-own-pair)
- [Tests](#tests)
- [When a push does not show up](#when-a-push-does-not-show-up)
- [Terms](#terms)

## The idea in one pass

```
HyperEVM                                        Elysium
HyperCore ──read──► Beacon ──Inbox (bridge)──► Receiver ──priceOf()──► your contract
                      ▲
                anyone calls push() and pays HYPE
```

1. Someone calls `Beacon.push(perps, gasLimit, maxFeePerGas)` and attaches HYPE.
2. In that same transaction the Beacon `staticcall`s HyperCore. Market `0x807` returns each
   perp's oracle price. Market `0x809` returns HyperCore's block number. The caller supplies
   the market indexes, not the prices.
3. The Beacon ABI-encodes `Receiver.update(perps, prices, hyperCoreBlock, readAt)` and hands
   that calldata to Elysium's Inbox via `createRetryableTicket`. `readAt` is HyperEVM's
   `block.timestamp` at that moment.
4. Elysium's sequencer waits until the HyperEVM block is safe from reorganisation, then runs
   the message as a transaction. On testnet that wait is 65–78 seconds. It is sequencer
   configuration (Nitro's delayed sequencer),
   so measure it again before relying on another deployment.
5. On Elysium, `msg.sender` is the Beacon's address plus
   `0x1111000000000000000000000000000000001111`. The Receiver stores the prices only when the
   caller is that aliased address, and only when the HyperCore block is strictly newer than
   the one already stored for each market.
6. Your contract calls `priceOf(perp, maxAge)`. You name the oldest reading you will accept.
   A stale or missing price reverts the call.

No server, keeper, or admin key sits between the precompile and the stored price. The
correctness of a reading rests on HyperEVM answering the precompile and on the bridge
delivering the Beacon's message unchanged.

## Why a bridge is required

HyperEVM and HyperCore share a node. A contract on HyperEVM reads the exchange with a
precompile: a `staticcall` to a fixed address that the node answers from its own HyperCore
copy. The oracle-price precompile is `0x807`. The docs are
[Interacting with HyperCore](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore).

Elysium is Kinetiq's Arbitrum Nitro chain. HyperEVM is its parent chain. An Elysium node runs
Nitro, so the same `staticcall` has no HyperCore data behind it. Kinetiq
[plans a HyperCore precompile](https://elysium.kinetiq.xyz/docs/what-is-elysium) about four
weeks after Elysium's mainnet launch. Until that ships, a contract on Elysium that wants these
prices has to receive them from HyperEVM.

Every Nitro chain already has a
[delayed inbox](https://docs.arbitrum.io/how-arbitrum-works/deep-dives/l1-to-l2-messaging#transacting-via-the-delayed-inbox):
a queue on the parent chain. Deposits use it. Any contract can use it too, by calling
`createRetryableTicket` on the chain's Inbox. Elysium uses this part of Nitro unchanged, so Arbitrum's docs apply as
written. The child-chain transaction is a
[retryable ticket](https://docs.arbitrum.io/how-arbitrum-works/deep-dives/l1-to-l2-messaging#retryable-tickets):
the sender pays the child chain's gas up front, on the parent chain, in the parent chain's
coin. Here that coin is HYPE on both sides, so the payment is plain `msg.value`.

## What gets stored

`Receiver.update` writes one `Reading` per market:

| Field | Set from | Used for |
|---|---|---|
| `price` | HyperCore oracle precompile `0x807` | the value `priceOf` returns |
| `hyperCoreBlock` | HyperCore block precompile `0x809` | ordering. A new reading must come from a strictly later HyperCore block |
| `readAt` | HyperEVM `block.timestamp` inside `push` | age. `priceOf` measures seconds from this instant, on Elysium's clock |
| `arrivedAt` | Elysium `block.timestamp` when `update` runs | your own diagnostics. `priceOf` does not read it |

`arrivedAt - readAt` is that push's bridge delay. On the demo pair one reading arrived 74
seconds after it was taken.

Age includes the bridge trip. `priceOf(perp, maxAge)` reverts with `TooOld` when
`block.timestamp - readAt > maxAge`. Ask for less than the bridge delay and the call reverts
even when the push just landed. With a push every 60 seconds and a delay of about 75 seconds,
a `maxAge` of 5 minutes leaves room for one missed push.

All four numbers share one HyperCore block. One `push` is one snapshot: every market in that
call is read, stamped, and delivered together. List each market once. A repeated index makes
`update` revert, and the whole batch is dropped.

Ordering uses the HyperCore block, not the price and not the clock. Two pushes that read the
same HyperCore block cannot both land. The second delivery reverts with `NotNewerThanStored`,
and the fee attached to it is spent. Run one pusher per pair.

## Who is allowed to write a price

The Receiver's constructor takes the Beacon's HyperEVM address and stores the aliased form:

```text
beacon on Elysium = beacon on HyperEVM + 0x1111000000000000000000000000000000001111
```

That addition is Nitro
[address aliasing](https://docs.arbitrum.io/how-arbitrum-works/deep-dives/l1-to-l2-messaging#address-aliasing).
It stops a contract on HyperEVM from being mistaken for the Elysium contract that happens to
have the same address. `Alias.sol` is that shift, both directions.

For the published testnet Beacon `0xA6Cc483A5257DFec4b7705468622aCCA2a4521d1`, the only address
`update` accepts is `0xB7dd483A5257DFec4b7705468622aCCA2a4532E2`.

Anyone can call `push` and pay the fee. The caller chooses the moment of the read. The Beacon
fills in the prices itself, in the same transaction, and it has no other write function. A
caller who wants a particular print can wait for it; they cannot pass their own number.
Contracts that act on one price, such as a liquidation, should allow for that delay. The
troubleshooting notes say the same thing.

Two addresses are fixed when the Beacon is deployed, and neither contract has an owner or an
upgrade path:

- `inbox` is the Inbox the Beacon pays. A Beacon constructed with some other contract will
  forward the attached HYPE there. After any deploy, read `inbox()` and confirm it is Elysium's
  Inbox.
- `receiver` is the Elysium address the message is aimed at. The Receiver, separately, only
  trusts the Beacon address it was constructed with.

A bug fix is a new pair. Point consumers at the new Receiver.

## What this is a good fit for

| | Native HyperCore precompile | This repo |
|---|---|---|
| Where it runs | HyperEVM | Elysium, fed from HyperEVM |
| Freshness | The current block | The last successful push, plus the bridge delay (65–78 s on testnet) |
| Who pays | Whoever reads, in gas | Whoever pushes, in HYPE on HyperEVM. Readers pay only their own gas |
| Data | Whatever HyperCore exposes | Perp oracle prices. Another precompile needs new code |
| Updates | Every block | Only after someone calls `push` and the delivery succeeds |

Oracle prices on HyperCore move about every 3 seconds. This path adds a minute of bridge time
and then sits still until the next push. That suits a value that is allowed to be a minute or
two old: a funding rate, a staking rate, a displayed mark. It does not suit order placement.
Lido publishes wstETH's rate on Optimism with the same parent-to-child ticket pattern
([their manual](https://docs.lido.fi/guides/verify-steth-on-optimism-upgrade-manual)).

The demo pair has no scheduled pusher, so its stored prices are usually old and `priceOf`
usually reverts. An application that depends on these prices runs the pushes itself.
[`script/push.sh`](script/push.sh) does one push, or repeats on `INTERVAL`.

## Repository map

| Path | Role |
|---|---|
| `src/HyperCore.sol` | `staticcall`s `0x807` and `0x809`. Reverts on a failed read or a zero price |
| `src/Beacon.sol` | HyperEVM. `read` for a dry run, `push` to send |
| `src/IInbox.sol` | The two Inbox functions the Beacon calls |
| `src/IReceiver.sol` | The single message both sides encode: `update(perps, prices, hyperCoreBlock, readAt)` |
| `src/Alias.sol` | Nitro's parent-to-child address shift |
| `src/Receiver.sol` | Elysium. Stores readings and serves `priceOf` |
| `script/push.sh` | Quotes the fee and sends `push` on a loop |
| `test/` | Forge tests. They fake HyperCore and the Inbox, so they need no RPC |
| `src/TROUBLESHOOTING.md` | Every revert and the usual operational failures |
| `foundry.toml` | Solidity 0.8.28, and the public testnet RPC names |

`foundry.toml` names the public RPCs `hyperevm_testnet` and `elysium_testnet`:

| Name | Chain | Chain id | URL |
|---|---|---|---|
| `hyperevm_testnet` | HyperEVM testnet | 998 | `https://rpc.hyperliquid-testnet.xyz/evm` |
| `elysium_testnet` | Elysium testnet | 99801 | `https://testnet-rpc.elysium.kinetiq.xyz` |

## Contract reference

### Beacon (HyperEVM)

Immutable for the life of the contract: `inbox()`, `receiver()`. Nothing else is stored.

`read(uint32[] perps) → (uint64[] prices, uint64 hyperCoreBlock)` is a dry run. It performs
the same precompile reads `push` will, and it can be called off-chain with `cast call`. A
missing market reverts `ReadFailed`. A zero oracle price reverts `PriceIsZero`, because a
failed decode must not look like a real price of zero.

`push(uint32[] perps, uint256 gasLimit, uint256 maxFeePerGas)` is payable and permissionless.

- `perps` empty reverts `NoMarketsGiven`.
- `gasLimit` and `maxFeePerGas` buy the Elysium transaction that will run `update`. The Inbox
  treats the value `1` as a request to revert, so both must be something else.
- The HYPE required is `submissionFee + gasLimit * maxFeePerGas`, where `submissionFee` comes
  from `inbox.calculateRetryableSubmissionFee(message.length, block.basefee)`. Too little
  reverts `NotEnoughPaid(needed, paid)`.
- The whole `msg.value` goes to the Inbox. Excess is refunded on Elysium to `msg.sender`
  (to the aliased address, if the caller is a contract). The Receiver itself is called with
  zero callvalue.
- The return value is the message number in Elysium's delayed inbox. It is not the retryable
  ticket id Elysium assigns later. The `Pushed` event carries that number, the HyperCore
  block, the indexes, and the prices.

### Receiver (Elysium)

Immutable: `beacon()`, already aliased.

`update(...)` is what the bridge calls. It reverts `NotTheBeacon` for every other caller,
`CountsDoNotMatch` when the two arrays differ in length, and `ReadInTheFuture` when `readAt`
is later than Elysium's clock. Inside the loop, a HyperCore block that is not strictly newer
reverts `NotNewerThanStored` and rolls the whole call back, so a duplicate market or a stale
batch leaves the previous readings in place. Each accepted market emits `Updated`.

`priceOf(uint32 perp, uint64 maxAge) → uint64` returns the raw price or reverts. There is no
default age and no silent zero.

`readingOf(uint32 perp) → (price, hyperCoreBlock, readAt, arrivedAt)` returns the stored
struct with no age check. It reverts `NothingForThisMarket` when that index has never been
delivered (`hyperCoreBlock == 0`).

## Reading a raw price as dollars

HyperCore stores a perp oracle price as an integer with `6 - szDecimals` decimal places
([tick and lot size](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/tick-and-lot-size)).
The contracts do not store `szDecimals` or the market's name. You take both from Hyperliquid's
market list, and the index in that list is the `uint32` you pass as `perp`.

Testnet and mainnet have different lists. On testnet, market 0 is SOL with `szDecimals` 2, so
you divide by `10^(6-2) = 10^4`. A raw price of `1014550` is `101.455` USD. On mainnet, market
0 is BTC with `szDecimals` 5, so you divide by `10^1`. The raw example in the tests, `815959`,
is `81595.9` USD.

Fetch the list you are actually targeting:

```bash
# testnet
curl -s https://api.hyperliquid-testnet.xyz/info -H 'Content-Type: application/json' \
  -d '{"type":"meta"}' | jq -r '.universe | to_entries[] | "\(.key) \(.value.name) \(.value.szDecimals)"'

# mainnet, for the index map only. This repo has no mainnet deployment.
curl -s https://api.hyperliquid.xyz/info -H 'Content-Type: application/json' \
  -d '{"type":"meta"}' | jq -r '.universe | to_entries[] | "\(.key) \(.value.name) \(.value.szDecimals)"'
```

## Quick start

Install [Foundry](https://getfoundry.sh/introduction/installation) (`forge` builds, tests, and
deploys; `cast` reads chains and sends transactions) and [`jq`](https://jqlang.org/download/).
`script/push.sh` is bash. On Windows, run it from Git Bash or WSL. `forge` and `cast` run in
PowerShell as they are.

From this folder:

```bash
forge test
```

The tests fake HyperCore and the bridge, so they need no RPC and no key. The first run
downloads Solidity 0.8.28.

Run the `cast` commands below from this folder so the RPC names in `foundry.toml` resolve.
The numbers change every time HyperCore moves.

**See what a push would send right now.** This calls `Beacon.read` on HyperEVM. It does not
spend HYPE and does not change Elysium.

```bash
BEACON=0xA6Cc483A5257DFec4b7705468622aCCA2a4521d1    # HyperEVM testnet
RECEIVER=0x12DdFB5e2Bf3544B5BE0Ac5aC9437d3c81fAdF47  # Elysium testnet

cast call $BEACON "read(uint32[])(uint64[],uint64)" "[0,1]" -r hyperevm_testnet
# [1014550 [1.014e6], 7167]    raw prices of markets 0 and 1
# 746303906 [7.463e8]          HyperCore block they were read at
```

`cast` prints a decimal hint in brackets, such as `[1.014e6]`. The first number on the line is
the chain value. `[0,1]` is the market indexes, in the order the prices come back.

**Read what Elysium already holds.**

```bash
cast call $RECEIVER "readingOf(uint32)((uint64,uint64,uint64,uint64))" 0 -r elysium_testnet
# (1019050, 746187272, 1792829003, 1792829077)
#  price, HyperCore block, readAt, arrivedAt   both times are Unix seconds

cast call $RECEIVER "priceOf(uint32,uint64)(uint64)" 0 300 -r elysium_testnet
# Error: execution reverted: TooOld(0, 7514, 300)
```

`TooOld(0, 7514, 300)` means market 0 was read 7514 seconds ago and this call allows 300.
That is the demo pair sitting idle, not a broken contract. A fresh push, then another minute
for the bridge, fills `readingOf` with a new block. `priceOf` then returns the raw integer.

**Check the two contracts point at each other.**

```bash
cast call $BEACON "inbox()(address)" -r hyperevm_testnet
# 0x11178Df40CBf87a4343f4B3F8B09B366ceFA8Ec0   Elysium's Inbox on HyperEVM testnet

cast call $BEACON "receiver()(address)" -r hyperevm_testnet
# 0x12DdFB5e2Bf3544B5BE0Ac5aC9437d3c81fAdF47

cast call $RECEIVER "beacon()(address)" -r elysium_testnet
# 0xB7dd483A5257DFec4b7705468622aCCA2a4532E2   Beacon + 0x1111…1111
```

## Call it from a contract

`priceOf` returns the raw `uint64`. Divide off-chain, or in the caller, by
`10^(6 - szDecimals)` using the list for that network. Keep the index and the divisor next to
each other: testnet market 0 and mainnet market 0 are different assets.

```solidity
interface IReceiver {
    function priceOf(uint32 perp, uint64 maxAge) external view returns (uint64);
}

contract Consumer {
    IReceiver immutable receiver;
    uint32 constant SOL_TESTNET = 0; // index 0 on testnet only
    uint64 constant MAX_AGE = 5 minutes;

    constructor(IReceiver receiver_) {
        receiver = receiver_;
    }

    /// Raw oracle price, or revert TooOld / NothingForThisMarket.
    function sol() external view returns (uint64) {
        return receiver.priceOf(SOL_TESTNET, MAX_AGE);
    }
}
```

`maxAge` counts from `readAt` on HyperEVM, so it has to cover the push interval and the bridge
delay. `priceOf` reverts rather than returning a stale or empty value, and that revert bubbles
into the consumer. Decide which actions should stop while the feed is stale. A caller that
wants to apply its own rule reads `readingOf` and uses `readAt`, `arrivedAt`, and
`hyperCoreBlock` itself. `readingOf` still reverts when the market has never arrived.

## What a push costs

One push pays two things, both in HYPE on HyperEVM:

1. A submission fee, so the Inbox accepts a message of this size. It depends on the calldata
   length and on HyperEVM's base fee.
2. `gasLimit * maxFeePerGas`, which prepays the Elysium gas that runs `Receiver.update`.

Anything above the amount actually used is refunded to the pusher's address on Elysium, not
on HyperEVM. A contract caller is refunded at its aliased address.

`script/push.sh` quotes both, then sends the transaction. It does not choose prices. Set:

| Variable | Required | Meaning |
|---|---|---|
| `HYPEREVM_RPC` | yes | HyperEVM URL, or the name `hyperevm_testnet` |
| `ELYSIUM_RPC` | yes | Elysium URL, or the name `elysium_testnet` |
| `BEACON` | yes | Beacon address. The script reads `inbox()` and `receiver()` from it |
| `PERPS` | yes | Comma-separated market indexes, such as `0,1`. The script adds the brackets |
| `INTERVAL` | no | Seconds between pushes. Unset means a single push |
| `ETH_KEYSTORE_ACCOUNT` | one of these | Name of a key created with `cast wallet new` |
| `ETH_KEYSTORE` | one of these | Path to a keystore file |
| `ETH_PASSWORD` | no | Path to a file holding the keystore password. Otherwise `cast` asks |

The quote can go stale before the transaction is mined, so the script doubles the base fee and
the gas price (`FEE_MARGIN=2`) and asks for 150% of the simulated Elysium gas
(`GAS_MARGIN_PERCENT=150`). The simulation calls `update` from the Receiver's `beacon()`
address, which is how the bridge will call it. The real `readAt` is not known yet; the script
uses `1` while estimating, because any timestamp uses the same amount of calldata. The extra
gas margin covers the difference.

Create a key and fund it with testnet HYPE from the
[Chainstack faucet](https://faucet.chainstack.com/) (Hyperliquid testnet), then push:

```bash
cast wallet new deployer
export ETH_KEYSTORE_ACCOUNT=deployer
cast wallet address --account deployer

HYPEREVM_RPC=hyperevm_testnet ELYSIUM_RPC=elysium_testnet \
  BEACON=$BEACON PERPS=0,1 script/push.sh

# same command with INTERVAL=60 keeps pushing once a minute
```

`cast` asks for the keystore password. The key is not written into the script. When the
HyperEVM transaction succeeds, the script prints the HyperCore block, the indexes, the wei
paid, and the transaction hash. Wait out the bridge delay, then read `readingOf` again. The
new `hyperCoreBlock` is the one the script printed.

Public RPCs are rate limited. For a loop, use your own HyperEVM and Elysium endpoints in
`HYPEREVM_RPC` and `ELYSIUM_RPC`. Append `/evm` to a Hyperliquid node URL.

## Deploy your own pair

The Receiver is deployed on Elysium, so the deployer address needs HYPE there. Bridge it
through the same Inbox. `depositEth` lands after the bridge delay; `cast balance` stays 0
until then.

```bash
H=hyperevm_testnet E=elysium_testnet
INBOX=0x11178Df40CBf87a4343f4B3F8B09B366ceFA8Ec0  # Elysium's Inbox on HyperEVM testnet
ME=$(cast wallet address --account deployer)

cast send $INBOX "depositEth()" --value 0.005ether -r $H
cast balance $ME -r $E
```

Each contract's constructor needs the other contract's address, and the Receiver must be told
the Beacon's real HyperEVM address so the alias matches. Predict the Beacon from this key's
next HyperEVM nonce, deploy the Receiver against that prediction, then deploy the Beacon.
Send nothing else from this key on HyperEVM in between, or the nonce moves and the Receiver
will trust an address you did not deploy.

```bash
BEACON=$(cast compute-address $ME --nonce $(cast nonce $ME -r $H) | awk '{print $NF}')

RECEIVER=$(forge create src/Receiver.sol:Receiver -r $E --broadcast --json \
  --constructor-args $BEACON | jq -r .deployedTo)

forge create src/Beacon.sol:Beacon -r $H --broadcast \
  --constructor-args $INBOX $RECEIVER
```

The Beacon line must print `Deployed to:` followed by the same address as `$BEACON`. Then
confirm the wiring with the three `cast call`s in the quick start: `inbox()` is the Inbox you
passed, `receiver()` is the new Receiver, and `beacon()` on Elysium is the Beacon plus the
alias offset. After that, `BEACON` and `RECEIVER` work with `push.sh` and `priceOf` unchanged.

If `forge create` prints a different Beacon address, the key sent another HyperEVM transaction
first. Deploy both contracts again. The old Receiver trusts a Beacon that does not exist, and
there is no function to retarget it.

## Tests

`forge test` runs three contracts. None of them talks to a network.

`Alias.t.sol` checks the shift against a real HyperEVM-to-Elysium message: an ERC-20 gateway
at `0x08922Faa84aC2a54aa3cFD3725b03ca256F52Da2` is recorded on Elysium as
`0x19A32fAA84Ac2A54AA3Cfd3725B03ca256F53Eb3`.

`Beacon.t.sol` plants stand-in bytecode at `0x807` and `0x809`, deploys a fake Inbox, and runs
one round trip by calling the Receiver from the Beacon's aliased address. It checks that the
raw price `815959` and HyperCore block `700_000_000` arrive intact.

`Receiver.t.sol` deploys the Receiver so that this test contract *is* the trusted beacon.
It checks a normal write, a stranger's revert (`NotTheBeacon`), a same-block overwrite
(`NotNewerThanStored`), and a price whose `readAt` is the Unix epoch (`TooOld`).

## When a push does not show up

A successful HyperEVM transaction only means the Inbox accepted the message. Elysium can still
refuse it. Delivery reverts do not appear on the HyperEVM receipt. If `readingOf` is unchanged
after two minutes, look at the Receiver on the
[Elysium testnet explorer](https://explorer-elysium-testnet.t.conduit.xyz/address/0x12DdFB5e2Bf3544B5BE0Ac5aC9437d3c81fAdF47)
and push again.

The usual causes, each spelled out in [`src/TROUBLESHOOTING.md`](src/TROUBLESHOOTING.md):

| What you see | What happened |
|---|---|
| `TooOld(perp, age, maxAge)` | The newest stored read is older than `maxAge` seconds. Push, wait for the bridge, retry |
| `NothingForThisMarket(perp)` | This Receiver has never stored that index |
| `ReadFailed` or `PriceIsZero` | That index is not a live perp on this network, or HyperCore returned 0. Drop it from `PERPS` |
| `NotEnoughPaid(needed, paid)` | The attached HYPE was below the fee `push` computed. Use the script, which quotes it |
| `NotNewerThanStored` on delivery | Same HyperCore block pushed twice, a market listed twice, or an older failed delivery retried after a newer one landed |
| Price unchanged, HyperEVM push succeeded | Elysium ran out of gas, or `update` reverted. Pushing again is the simple fix. A failed ticket can also be redeemed within a week |
| Refund missing on HyperEVM | Refunds are paid on Elysium, to the same address |

## Terms

| Term | What it is |
|---|---|
| [Hyperliquid](https://hyperliquid.gitbook.io/hyperliquid-docs) | A blockchain built around a trading exchange. It runs HyperCore and HyperEVM under one consensus |
| HyperCore | The exchange: order books, balances, and prices. Not an EVM, and it has its own block numbers |
| [HyperEVM](https://hyperliquid.gitbook.io/hyperliquid-docs/hyperevm) | The smart-contract chain next to HyperCore. Coin HYPE, testnet chain id 998 |
| [Precompile](https://www.evm.codes/precompiled) | A built-in contract at a fixed address, implemented by the node |
| [Perp](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/perpetual-assets) | A perpetual futures market on HyperCore, numbered by its index in the market list |
| [Oracle price](https://hyperliquid.gitbook.io/hyperliquid-docs/hypercore/oracle) | The price HyperCore's validators publish per perp about every 3 seconds, from large exchanges. This repo carries that price |
| [Elysium](https://elysium.kinetiq.xyz/docs/what-is-elysium) | Kinetiq's Arbitrum Nitro chain with HyperEVM as its parent. Gas in HYPE, testnet chain id 99801 |
| [Arbitrum Nitro](https://docs.arbitrum.io/welcome/arbitrum-gentle-introduction) | The software behind Arbitrum and many other chains. Each settles to a parent chain and takes messages from it |
| [Sequencer](https://docs.arbitrum.io/how-arbitrum-works/sequencer) | The node that orders a Nitro chain's transactions. Elysium's is run by Conduit |
| Delayed inbox | The parent-chain queue a Nitro chain reads messages from, including deposits and these price updates |
| Retryable ticket | The child-chain transaction created from one inbox message. Gas is prepaid on the parent |
| Address aliasing | The fixed offset Nitro adds to a parent-chain sender before it is seen on the child chain |

## License

Apache 2.0, as marked in the `SPDX-License-Identifier` header of each source file.

---

Unofficial community project. Not affiliated with Kinetiq/Hyperliquid.
