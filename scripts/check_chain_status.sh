#!/bin/bash
set -e

CHAIN_ID="${CHAIN_ID:-neutron}"
RPC_ADDRESS="${RPC_ADDRESS}"

# setup neutrond config in default config folder
mkdir -p /root/.neutrond
neutrond config chain-id $CHAIN_ID
neutrond config node $RPC_ADDRESS
neutrond config keyring-backend test

echo "CHAIN_ID: $CHAIN_ID"
echo "NODE: $RPC_ADDRESS"

# check binary version status for daemon commands
echo "neutrond version: $( neutrond version )"
if [[ $? -ne 0 ]]; then
    echo "Cannot send neutrond commands to Neutron testnet"
    exit 1
fi

echo "Connecting to testnet: $RPC_ADDRESS ..."
# check if we can get information from the testnet
abci_info=$(
    curl \
        --connect-timeout 1 \
        --max-time 3 \
        --retry 30 \
        --retry-connrefused \
        --retry-delay 1 \
        --silent \
        $RPC_ADDRESS/abci_info
)
if [[ "$( echo $abci_info | jq -r ".result.response.data" )" != "neutrond" ]]
then
    echo "Could not establish connection to Neutron testnet"
    exit 1
fi

echo "Neutron testnet available"

# check that the expected chain is found if specified
if [ ! -z "$CHAIN_ID" ]
then
    status=$( curl --connect-timeout 1 --max-time 3 --retry 30 --retry-connrefused --retry-delay 1 -s $RPC_ADDRESS/status )
    found_network=$( echo $status | jq -r ".result.node_info.network" )
    if [[ "$found_network" == "$CHAIN_ID" ]]
    then
        echo "Neutron testnet has expected chain: $CHAIN_ID"
    else
        echo "Neutron testnet has unexpected chain: $found_network (expected $CHAIN_ID)"
        exit 1
    fi
fi

# wait for testnet to be ready (block must be started for txs to be processed)
latest_height=0
while [[ "$latest_height" -lt 1 ]]
do
    latest_block=$(
        curl \
            --connect-timeout 1 \
            --max-time 3 \
            --retry 3 \
            --retry-connrefused \
            --retry-delay 1 \
            --silent \
            $RPC_ADDRESS/status
    )
    latest_height="$( echo $latest_block | jq -r '.result.sync_info.latest_block_height' )"
done

echo "Neutron testnet ready"
