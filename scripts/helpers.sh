#!/bin/bash
set -e

# alias neutrond to a specific Docker neutrond
neutrond() {
    docker exec $NEUTROND_NODE neutrond --home /opt/neutron/data/$CHAIN_ID "$@"
}

getDockerEnv() {
    # get this Docker container env info
    curl -s --unix-socket /run/docker.sock http://docker/containers/$HOSTNAME/json
}
getDockerEnvs() {
    docker_env=${1:-"$( getDockerEnv )"}
    docker_image=$( echo "$docker_env" | jq -r '.Config.Image' )
    docker inspect $( docker ps --filter "ancestor=$docker_image" -q )
}

getBotNumber() {
    docker_service_number=$(
        echo "$( getDockerEnv )" | jq -r '.Config.Labels["com.docker.compose.container-number"]'
    )
    if [ "$docker_service_number" -gt "0" ]
    then
        echo "$docker_service_number";
    fi
}

getBotStartTime() {
    bot_number=${1:-"$( getBotNumber )"}
    # get global start time from the creation of the first bot
    global_start_time="$( echo "$( getDockerEnvs )" | jq -r '.[0].Created' )"
    global_start_epoch="$( date -u -d "$global_start_time" -D '%Y-%m-%dT%H:%M:%S' +'%s' )"
    echo "$(( ($bot_number - 1) * $BOT_RAMPING_DELAY + $global_start_epoch ))"
}
getBotEndTime() {
    bot_number=${1:-"$( getBotNumber )"}
    TRADE_DURATION_SECONDS="${TRADE_DURATION_SECONDS:-0}"
    if [ $TRADE_DURATION_SECONDS -gt 0 ]
    then
        start_time=$( getBotStartTime $bot_number )
        echo "$(( $start_time + $TRADE_DURATION_SECONDS ))"
    fi
}

createAndFundUser() {
    tokens=$1
    # create person name
    person=$(openssl rand -hex 12)
    # stagger the creationi of wallets on chain to avoid race conditions and "out of sequence" issues here:
    BOT_RAMPING_DELAY="${BOT_RAMPING_DELAY:-5}"
    # enforce a minimum delay, a safe delay is at least one block space in seconds (which may be hard to predict)
    # a 6 second delay was needed to run more than 40 bots reliably
    BOT_RAMPING_DELAY=$(( $BOT_RAMPING_DELAY > 3 ? $BOT_RAMPING_DELAY : 3 ))
    bot_number=$( getBotNumber )
    sleep $(( $bot_number > 0 ? ($bot_number -1) * $BOT_RAMPING_DELAY : 0 ))
    echo "funding new user: $person with tokens $tokens" > /dev/stderr
    # create person's new account (with a random name and set passphrase)
    # the --no-backup flag only prevents output of the new key to the terminal
    neutrond keys add $person --no-backup > /dev/stderr
    # send funds from frugal faucet friend (one of 3 denomwallet accounts)
    faucet="demowallet$(( $RANDOM % 3 + 1 ))"
    response=$(
        neutrond tx bank send \
            $( neutrond keys show $faucet -a ) \
            $( neutrond keys show $person -a ) \
            $tokens \
            --broadcast-mode sync \
            --output json \
            --gas auto \
            --gas-adjustment $GAS_ADJUSTMENT \
            --gas-prices $GAS_PRICES \
            --yes
    )
    if [ "$( echo $response | jq -r '.code' )" -eq "0" ]
    then
        tx_hash=$( echo $response | jq -r '.txhash' )
        # get tx result for msg
        tx_result=$(waitForTxResult "$API_ADDRESS" "$tx_hash")

        echo "funded new user: $person with tokens $tokens" > /dev/stderr

        # return only person name for test usage
        echo "$person"
    else
        echo "funding new user error (code: $( echo $response | jq -r '.code' )): $( echo $response | jq -r '.raw_log' )" > /dev/stderr
    fi
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
