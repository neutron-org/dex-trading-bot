#!/bin/bash
set -e

# alias neutrond to a specific Docker neutrond
neutrond() {
    docker exec $NEUTROND_NODE neutrond --home /opt/neutron/data/$CHAIN_ID "$@"
}

createAndFundUser() {
    tokens=$1
    # create person name
    person=$(openssl rand -hex 12)
    echo "funding new user: $person with tokens $tokens" > /dev/stderr
    # create person's new account (with a random name and set passphrase)
    # the --no-backup flag only prevents output of the new key to the terminal
    neutrond keys add $person --no-backup > /dev/stderr
    # send funds from frugal faucet friend (one of 3 denomwallet accounts)
    faucet="demowallet$(( $RANDOM % 3 + 1 ))"
    tx_hash=$(
        neutrond tx bank send \
            $( neutrond keys show $faucet -a ) \
            $( neutrond keys show $person -a ) \
            $tokens \
            --broadcast-mode sync \
            --output json \
            --fees 500untrn \
            --yes \
            | jq -r '.txhash'
    )
    # get tx result for msg
    tx_result=$(waitForTxResult "$API_ADDRESS" "$tx_hash")

    echo "funded new user: $person with tokens $tokens" > /dev/stderr

    # return only person name for test usage
    echo "$person"
}

throwOnTxError() {
    test_name=$1
    tx_result=$2
    tx_code=$( echo $tx_result | jq -r .tx_response.code )
    if [[ "$tx_code" == "" ]]
    then
        echo "$test_name: error (tx_reponse code not found) with tx_hash: \"$tx_hash\""
        exit 1
    elif [[ "$tx_code" != "0" ]]
    then
        tx_hash=$( echo $tx_result | jq -r .tx_response.txhash )
        tx_log=$( echo $tx_result | jq -r .tx_response.raw_log )
        echo "$test_name: error ($tx_code) at $tx_hash: $tx_log"
        exit $tx_code
    fi
}

waitForTxResult() {
    api=$1
    hash=$2
    echo "making request: for result of tx hash $api/cosmos/tx/v1beta1/txs/$hash" > /dev/stderr
    echo "$(
      curl \
      --connect-timeout 10 \
      --fail \
      --retry 30 \
      --retry-connrefused \
      --retry-max-time 30 \
      --retry-delay 1 \
      --retry-all-errors \
      -s $api/cosmos/tx/v1beta1/txs/$hash
    )"
}


# below code is taken from https://stackoverflow.com/questions/8818119/how-can-i-run-a-function-from-a-script-in-command-line#16159057

# Check if the function exists (bash specific)
if declare -f "$1" > /dev/null
then
    # call arguments verbatim
    "$@"
else
    # Show a helpful error
    echo "'$1' is not a known function name" >&2
    exit 1
fi
