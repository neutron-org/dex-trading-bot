# A Dex Trading Bot

## Requirements
- git
- Docker
- make

## Get Started

To run the bot, you will first need a chain to run the bot against,
locally this should be a single dockerized neutron node
- `make build-neutron`

To run the default setup of a single neutron-node chain and a single trading bot with a single wallet:
- `make start-trade-bot MNEMONIC=...`
- the available `MNENOMIC` options are explained in the [Options section](#mnemonic-options)

This composed neutron chain and trading bot network will persist until you call:
- `make stop-trade-bot`

### Test runs (start+stop)
You can test a chain and bot(s) configuration and exit with cleanup in one step using:
- `make test-trade-bot MNEMONIC=...`

However the default settings are quite conservative, and won't product many txs.
A larger test which should generate approximately ~1000-2000 txs in ~6 minutes with 30 bots could be done with:
- `make test-trade-bot BOTS=30 BOT_RAMPING_DELAY=5 TRADE_FREQUENCY_SECONDS=0 TRADE_DURATION_SECONDS=180 MNEMONIC=...`

This can be ideal for CI type testing of a service that depends on Dex transactions on a Neutron chain.
But if you want the chain to persist after the trades are completed (with a finite `TRADE_DURATION_SECONDS`),
then `make start-trade-bot` should be used instead.

## Available options

### Mnemonic options
A single mnenomic option must be used to run `make start-trade-bot` or `make test-trade-bot` this may be in the form of:
- a list of mnemonics to be used (delimited with any `\r\n,;` characters) where one mnemonic is given to each bot.
An error will be thrown if not enough mnemonics are provided for the number of `BOTS` requested.
    - `MNEMONIC`
    - `MNEMONICS`
    - `BOT_MNEMONIC`
    - `BOT_MNEMONICS`
- a single mnenomic which will be used to like a faucet to fund a separate randomly generated wallet for each bot
(so you may easily run more than one bot with one wallet).
    - `FAUCET_MNEMONIC`
    - on simulation end: the remaining token balance will be refunded to the faucet wallet.
    - you should strongly consider using `ON_EXIT_WITHDRAW_POOLS=1` when using this option on a testnet.
    If the pools are not withdrawn and you have not saved the randomly generated mnenomics for each bot
    then ***you will lose access to these deposited tokens***.
- if you are running a local chain you can use the DEMO_MNEMONICs from the neutron repo
[networks/init.sh](https://github.com/neutron-org/neutron/blob/v3.0.0/network/init.sh#L19-L21) file for these settings.

### Optional options

All docker-compose env vars are able to be set in both `make start-trade-bot` and `make test-trade-bot`
- Chain variables
    - `CHAIN_ID`: the chain ID
    - `LOG_LEVEL`: which logs should be visible from the chain
    - `GRPC_PORT`: the GRPC port number
    - `GRPC_WEB`: the GRPC-web port number
- Trading bot variables:
    - `RPC_ADDRESS`: RPC address of chain
    - `API_ADDRESS`: API address of chain
    - `BOTS`: number of trading bots to run
    - `BOT_RAMPING_DELAY`: seconds between starting each bot
    - `TRADE_DURATION_SECONDS`: how long trades should occur for
    - `TRADE_FREQUENCY_SECONDS`: how many seconds to delay between trades on a bot
    - `ON_EXIT_WITHDRAW_POOLS`: if set, withdraw all user's Dex pools after TRADE_DURATION_SECONDS
    - `GAS_ADJUSTMENT`: how much more than the base estimated gas price to pay for each tx
    - `GAS_PRICES`: calculate how many fees to pay from this fraction of gas
    - `TOKEN_CONFIG`: a token pairs configuration (JSON) object to specify trading behavior to use for each token pair
        - see the [TOKEN_CONFIG option section](#token_config-option) for more details
    - `COINGECKO_API_TOKEN`: a Coingecko API token used for live prices fetching. Only used with respective token pair price setting. The token should be a [demo API token](https://www.coingecko.com/en/api/pricing). Pro tokens aren't supported because they use different endpoints. Keep in mind the very limited request rate the demo tokens provide when configuring the bots number and trading intensity.

eg. `make start-trade-bot BOTS=30 BOT_RAMPING_DELAY=5 TRADE_FREQUENCY_SECONDS=0 TRADE_DURATION_SECONDS=450 MNEMONIC=...`
will start a persistent chain that for the first ~10min (7min+ramping) will generate ~5000txs using 30 bots.

#### TOKEN_CONFIG option

format for TOKEN_CONFIG is:
```
TOKEN_CONFIG = {
    "amountAtokenA<>amountBtokenB": numeric_price_or_PAIR_CONFIG_object,
    "defaults": PAIR_CONFIG
}
```
the object keys are the usable tokens for each pair (to be shared across all bots),
the object values are the price ratio of tokenB/tokenA, a coingecko pair or a config object: (default values are listed)
```
PAIR_CONFIG = {
  "price":            1,                              # price ratio is of tokenB/tokenA (how many tokenA is required to buy 1 tokenB?), OR
  "price":            "coingecko:api_idA<>api_idB",   # for live price retrieval, use the coingecko API IDs of the tokens (e.g. "coingecko:cosmos<>neutron-3" for atom<>ntrn pair)
  "ticks":            100,                            # number of ticks for each bot to deposit
  "fees":             [1, 5, 20, 100]                 # each LP deposit fee may be (randomly) one of the whitelisted fees here
  "gas":              "0untrn"                        # additional gas tokens that bots can use to cover gas fees
  "rebalance_factor": 0.5,                            # fraction of excessive deposits on either pair side to rebalance on each trade
  "deposit_factor":   0.5,                            # fraction of the recommended maximum reserves to use on a single tick deposit
  "swap_factor":      0.5,                            # max fraction of a bot's token reserves to use on a single swap trade (max: 1)
  "swap_accuracy":    100,                            # ~1% of price:     swaps will target within ~1% of current price
  "deposit_accuracy": 1000,                           # ~10% of price:    deposits will target within ~10% of current price
  "amplitude1":       5000,                           # ~50% of price:    current price will vary by ~50% of set price ratio
  "period1":          36000,                          # ten hours:        current price will cycle min->max->min every ten hours
  "amplitude2":       1000,                           # ~10% of price:    current price will vary by an additional ~10% of price ratio
  "period2":          600,                            # ten minutes:      current price will cycle amplitude2 offset every ten minutes
}
```

For example the following `TOKEN_CONFIG` option sets each bot to trade on 3 pools
- the first `uibcusdc<>uibcatom` with all default options except price of `1uibcatom = 10uibcusdc`
- the second `untrn<>uibcusdc` with custom GoinGecko pricing and specified 50 deposited ticks
- the third `untrn<>uibcatom` with custom sinusoidal pricing around a price of `1uibcatom = 5untrn`
- all pools will operate with the specified `defaults` values of `fees` and `gas`
```js
TOKEN_CONFIG = {
    "10000000000000uibcusdc<>10000000000000uibcatom": 10,
    "100000000000untrn<>100000000000uibcusdc":{
        "price": "coingecko:neutron-3<>usd-coin",
        "ticks": 50
    },
    "1000000000uibcatom<>1000000000untrn":{
        "price": 5,
        "amplitude2": 100
    },
    "defaults":{
        "fees": [0,1,2,3,4,5,10,20,50,100,150,200],
        "gas": "1000000000untrn"
    }
}
```

# Troubleshooting

The chain should be visible at http://localhost:26657 and REST at http://localhost:1317.

If you cannot contact these addresses from within a different Docker service (such as a local indexer), try using:
```
RPC_API=http://host.docker.internal:26657
REST_API=http://host.docker.internal:1317
```
