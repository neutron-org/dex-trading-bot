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
    - `GAS_ADJUSTMENT`: how much more than the base estimated gas price to pay for each tx
    - `GAS_PRICES`: calculate how many fees to pay from this fraction of gas

eg. `make start-trade-bot BOTS=30 BOT_RAMPING_DELAY=5 TRADE_FREQUENCY_SECONDS=0 TRADE_DURATION_SECONDS=450`
will start a persistent chain that for the first ~10min (7min+ramping) will generate ~5000txs using 30 bots.
