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
- `make start-trade-bot MNEMONIC=...`
- at least a single mnenomic must be specified from the mnenomics listed in the options section below
    - `MNEMONIC`
    - `MNEMONICS`
    - `BOT_MNEMONIC`
    - `BOT_MNEMONICS`
    - `FAUCET_MNEMONIC`
    - `FAUCET_MNEMONICS`

This composed neutron chain and trading bot network will persist until you call:
- `make stop-trade-bot`

### Changing versions
You can run a newer version of the chain than the default in the makefile
- `make build-neutron NEUTRON_VERSION="fix/swap-rounding"`
- `make start-trade-bot NEUTRON_VERSION="v3.0.1" MNEMONIC=...`
In this case, the trade bots will use the v3.0.1 binary to make requests to the
local chain running a fix branch (which is compatible with the v3.0.1 requests)

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
        - see [helpers.sh](https://github.com/neutron-org/dex-trading-bot/blob/e0f6f7128182b9dce2a54abbee279219ae8dc9fc/scripts/helpers.sh#L41-L59) for more setting details
    - mnemonics:
        - `FAUCET_MNEMONIC` (optional): the mnemonic of the account that will fund generated bots
        - `BOT_MNEMONIC/S` or `MNEMONIC/S` (optional): the mnemonics for self-funded bot account(s)
        - at least one of `FAUCET_MNEMONIC` or `BOT_/MNEMONIC/S` should be provided
        - with a local chain you can use `DEMO_MNEMONIC`s from the neutron networks/init.sh file

eg. `make start-trade-bot BOTS=30 BOT_RAMPING_DELAY=5 TRADE_FREQUENCY_SECONDS=0 TRADE_DURATION_SECONDS=450 MNEMONIC=...`
will start a persistent chain that for the first ~10min (7min+ramping) will generate ~5000txs using 30 bots.

## Save the current chain data

You can save the current chain data of a running chain by running
```shell
make save-neutron-node TAG_NAME="[optional tag description]"
```
This will save a new Docker image tagged: `neutron-node:[description]`

if the chain isn't currently running but you haven't yet cleaned out the volume
then you can:
- restart the chain itself using `make start-neutron-node`
- run the save data script: `make save-neutron-node TAG_NAME="[optional tag description]"`
- remove the chain using `make stop-neutron-node`

To run the chain with this saved state you can:
- run the resume data script: `make resume-neutron-node TAG_NAME="[optional tag description]"` or
- run the resume data script: `make start-neutron-node TAG_NAME="[tag description]"`

# Troubleshooting

The chain should be visible at http://localhost:26657 and REST at http://localhost:1317.

If you cannot contact these addresses from within a different Docker service (such as a local indexer), try using:
```
RPC_API=http://host.docker.internal:26657
REST_API=http://host.docker.internal:1317
```
