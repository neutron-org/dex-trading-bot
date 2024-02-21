#!/bin/bash
set -e

getDockerEnv() {
    # get this Docker container env info
    curl -s --unix-socket /run/docker.sock http://docker/containers/$HOSTNAME/json
}
getDockerEnvs() {
    docker_env="${1:-"$( getDockerEnv )"}"
    docker_image=$( echo "$docker_env" | jq -r '.Config.Image' )
    docker inspect $( docker ps --filter "ancestor=$docker_image" -q )
}

getBotNumber() {
    docker_env="${1:-"$( getDockerEnv )"}"
    docker_service_number=$(
        echo "$docker_env" | jq -r '.Config.Labels["com.docker.compose.container-number"]'
    )
    if [ "$docker_service_number" -gt "0" ]
    then
        echo "$docker_service_number";
    fi
}
getDockerEnvOfBotNumber() {
    # ask for a specific bot number
    bot_number=$1
    # get this Docker container env info
    docker_env="$( getDockerEnv )"
    # return asked for bot env
    if [ "$bot_number" -gt 0 ] && [ "$( getBotNumber "$docker_env" )" -ne "$bot_number" ]
    then
        # return the matching bot number from the list of all bot Docker envs
        docker_envs=$( getDockerEnvs "$docker_env" )
        echo "$docker_envs" | jq -r ".[] | select(.Config.Labels[\"com.docker.compose.container-number\"] == \"$bot_number\")"
    else
        echo "$docker_env"
    fi
}

getBotStartTime() {
    bot_number=${1:-"$( getBotNumber )"}
    # source the start time from the first bot
    if [ "$bot_number" -eq "1" ]
    then
        first_bot_start_time="$EPOCHSECONDS"
        echo "$first_bot_start_time"
        # write start time to file for other bots to query
        echo "$first_bot_start_time" > start_time
    else
        first_bot_container="$( echo "$( getDockerEnvOfBotNumber 1 )" | jq -r '.Config.Hostname' )"
        while [ -z "$first_bot_start_time" ]
        do
            first_bot_start_time=$( docker exec $first_bot_container cat start_time 2>/dev/null || true )
            if [ -z "$first_bot_start_time" ]
            then
                echo "waiting for first bot to start..." > /dev/stderr
                sleep 1
            fi
        done
        echo "waited. found: $first_bot_start_time" > /dev/stderr
        echo "$(( ($bot_number - 1) * $BOT_RAMPING_DELAY + $first_bot_start_time ))"
    fi
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
waitForAllBotsToSynchronizeToStage() {
    stage_name="$1"
    wait_time="${2:-3}"
    docker_envs="$( getDockerEnvs )"
    docker_envs_count="$( echo "$docker_envs" | jq -r 'length' )"
    filename="${stage_name}_time"
    echo "bot sync: wait for stage $stage_name ..." > /dev/stderr
    if [ "$docker_envs_count" -gt 1 ]
    then
        # write time to file for other bots to query
        echo "$EPOCHSECONDS" > $filename
        # query all containers for their time, one by one
        for (( i=0; i<$docker_envs_count; i++ ))
        do
            docker_env="$( echo "$docker_envs" | jq ".[$i]" )"
            nth_bot_container="$( echo "$docker_env" | jq -r '.Config.Hostname' )"
            nth_bot_end_time=""
            while [ -z "$nth_bot_end_time" ]
            do
                nth_bot_end_time=$( docker exec $nth_bot_container cat $filename 2>/dev/null || true )
                if [ -z "$nth_bot_end_time" ]
                then
                    sleep "$wait_time"
                    echo "bot sync: wait for stage $stage_name, still waiting ..." > /dev/stderr
                fi
            done
        done
        echo "bot sync: synced to stage $stage_name" > /dev/stderr
    fi
}

createMnemonic() {
    docker_env="${1:-"$( getDockerEnv )"}"
    # create mnenomic from container Env (without line breaks)
    neutrond keys mnemonic --keyring-backend test --unsafe-entropy <<EOF
"$( echo "$docker_env" | jq '.Config' | xargs echo -n )"
y
EOF
}

createUser() {
    docker_env="${1:-"$( getDockerEnv )"}"
    # create mnenomic from container Env (without line breaks)
    mnemonic=$( createMnemonic "$docker_env" )
    echo "mnemonic: $mnemonic" > /dev/stderr
    # add the new account under hostname
    person="$( echo "$docker_env" | jq -r '.Config.Hostname' )"
    echo "creating user: $person" > /dev/stderr
    echo "$mnemonic" | neutrond keys add $person --recover > /dev/stderr
    echo "$person";
}

getFaucetWallet() {
    # get passed bot number or derive it from environment
    bot_number=${1:-"$( getBotNumber )"}
    # if mnenomics are defined then take wallet from a given mnemonic
    MNEMONICS="${MNEMONICS:-"$MNEMONIC"};"
    mnemonics_array=()
    i=1
    while mnemonic=$(echo "$MNEMONICS" | cut -d\; -f$i | xargs echo -n); [ -n "$mnemonic" ]
    do
        mnemonics_array+=( "$mnemonic" )
        i=$(( i+1 ))
    done
    if [ "${#mnemonics_array[@]}" -gt 0 ]
    then
        # pick the mnenomic to use out of the valid array
        bot_index=$(( ($bot_number - 1) % ${#mnemonics_array[@]} ))
        mnemonic=$(echo "${mnemonics_array[$bot_index]}")
        # add the faucet account
        person="faucet"
        echo "$mnemonic" | neutrond keys add $person --recover > /dev/null
        echo "$person";
    else
        echo "at least one mnemonic should be provided in MNEMONIC/MNEMONICS"
        exit 1
    fi
}

fundUser() {
    tokens=$1
    person="${2:-$( createUser )}"
    # stagger the funding of wallets on chain to avoid race conditions and "out of sequence" issues here:
    # a 6 second delay was needed to run more than 40 bots reliably
    funding_delay=6
    bot_number=$( getBotNumber )
    sleep $(( $bot_number > 0 ? ($bot_number -1) * $funding_delay : 0 ))
    echo "funding user: $person with tokens $tokens" > /dev/stderr
    # send funds from frugal faucet friend (from MNEMONICS)
    faucet="$( getFaucetWallet )"
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
