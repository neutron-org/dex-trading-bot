# A Dex Trading Bot

## Requirements
- git
- Docker
- make

## Get Started

To run the bot, you will first need a chain to run the bot against,
locally this should be a single dockerized neutron node
- `make build-neutron`

To run the default setup of a single neutron-node chain and a single trading bot:
- `make start-trade-bot`

This composed neutron chain and trading bot network will persist until you call:
- `make stop-trade-bot`

### Test runs (start+stop)
You can test a chain and bot(s) configuration and exit with cleanup in one step using:
- `make test-trade-bot`

However the default settings are quite conservative, and won't product many txs.
A larger test which should generate approximately ~1000-2000 txs in ~6 minutes with 30 bots could be done with:
- `make test-trade-bot BOTS=30 BOT_RAMPING_DELAY=5 TRADE_FREQUENCY_SECONDS=0 TRADE_DURATION_SECONDS=180`

This can be ideal for CI type testing of a service that depends on Dex transactions on a Neutron chain.
But if you want the chain to persist after the trades are completed (with a finite `TRADE_DURATION_SECONDS`),
then `make start-trade-bot` should be used instead.

## Available options

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
    - `TOKEN_CONFIG`: a token pairs configuration (JSON) object for eg. token amounts to trade
        - see [helpers.sh](https://github.com/neutron-org/dex-trading-bot/blob/131a5f1590483840305cb475f8a867996509333e/scripts/helpers.sh#L41-L63) for more setting details
    - mnemonics:
        - `FAUCET_MNEMONIC` (optional): the mnemonic of the account that will fund generated bots
        - `BOT_MNEMONIC/S` or `MNEMONIC/S` (optional): the mnemonics for self-funded bot account(s)
        - at least one of `FAUCET_MNEMONIC` or `BOT_/MNEMONIC/S` should be provided
        - with a local chain you can use `DEMO_MNEMONIC`s from the neutron networks/init.sh file
    - `COINGECKO_API_TOKEN`: a Coingecko API token used for live prices fetching. Only used with respective token pair price setting. The token should be a [demo API token](https://www.coingecko.com/en/api/pricing). Pro tokens aren't supported because they use different endpoints. Keep in mind the very limited request rate the demo tokens provide when configuring the bots number and trading intensity.

eg. `make start-trade-bot BOTS=30 BOT_RAMPING_DELAY=5 TRADE_FREQUENCY_SECONDS=0 TRADE_DURATION_SECONDS=450 MNEMONIC=...`
will start a persistent chain that for the first ~10min (7min+ramping) will generate ~5000txs using 30 bots.

# Troubleshooting

The chain should be visible at http://localhost:26657 and REST at http://localhost:1317.

If you cannot contact these addresses from within a different Docker service (such as a local indexer), try using:
```
RPC_API=http://host.docker.internal:26657
REST_API=http://host.docker.internal:1317
```
