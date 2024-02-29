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
getBotCount() {
    docker_envs="${1:-"$( getDockerEnvs )"}"
    # count all matching bot docker envs as bots
    echo "$docker_envs" | jq -r 'length'
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

# format for TOKEN_CONFIG is:
# TOKEN_CONFIG = {
#   "amount0token0<>amount1token1": numeric_price_or_PAIR_CONFIG_object,
#   "defaults": PAIR_CONFIG
# }
# the object keys are the usable tokens for each pair (to be shared across all bots),
# the object values are the price ratio of token1/token0 or a config object: (default values are listed)
# PAIR_CONFIG = {
#   "price":            1,              # price ratio is of token1/token0 (how many token0 is required to buy 1 token1?)
#   "ticks":            100,            # number of ticks for each bot to deposit
#   "fees":             [1, 5, 20, 100] # each LP deposit fee may be (randomly) one of the whitelisted fees here
#   "gas":              "0untrn"        # additional gas tokens that bots can use to cover gas fees
#   "swap_accuracy":    100,            # ~1% of price:     swaps will target within ~1% of current price
#   "deposit_accuracy": 1000,           # ~10% of price:    deposits will target within ~10% of current price
#   "amplitude1":       5000,           # ~50% of price:    current price will vary by ~50% of set price ratio
#   "period1":          36000,          # ten hours:        current price will cycle min->max->min every ten hours
#   "amplitude2":       1000,           # ~10% of price:    current price will vary by an additional ~10% of price ratio
#   "period2":          600,            # ten minutes:      current price will cycle amplitude2 offset every ten minutes
# }
# which is transformed to format for token_config_array = [
#   {
#     "pair": [
#       {
#         "amount": "10000000000", # <-- this is the amount for one bot
#         "denom": "uibcatom"
#       },
#       {
#         "amount": "10000000000", # <-- this is the amount for one bot
#         "denom": "uibcusdc"
#       }
#     ],
#     "config": PAIR_CONFIG
#   }
# ]
getTokenConfigArray() {
    # remove "defaults" to save as default config
    # convert object to array
    # then convert numeric config (price) to object config
    # then parse out the config key into a pair description of each variable
    # default values are set by using the syntax (.x // default_x)
    # docs: https://jqlang.github.io/jq/manual/#alternative-operator

    # split the total tokens budget across each bot so each env doesn't need to worry about the number of bots
    # this includes extra gas passed in the config or default config object
    bot_count=$( getBotCount )
    # by default shift the period of each token pair slightly so they are not exactly in sync
    echo "${TOKEN_CONFIG:-"$TOKEN_CONFIG_DEFAULT"}" | jq -r '
        .defaults as $defaults
        | del(.defaults)
        | to_entries
        | map(if .value | type == "number" then .value = { price: .value } else . end)
        | map(.value * {
            pair: (
                .key
                | split("<>")
                | map(
                    capture("(?<amount>[0-9]+)(?<denom>.+)")
                    | .amount = ((.amount | tonumber) / '$bot_count' | floor)
                )
            ),
        })
        # use array to get index keys (.key) for default amplitude periods
        | to_entries
        | map({
            pair: .value.pair,
            config: {
                price: (.value.price // $defaults.price // 1),
                ticks: (.value.ticks // $defaults.ticks // 100),
                fees: (.value.fees // $defaults.fees // [1, 5, 20, 100]),
                swap_accuracy: (.value.swap_accuracy // $defaults.swap_accuracy // 100),
                deposit_accuracy: (.value.deposit_accuracy // $defaults.deposit_accuracy // 1000),
                amplitude1: (.value.amplitude1 // $defaults.amplitude1 // 5000),
                period1: (.value.period1 // $defaults.period1 // (36000 + .key)),
                amplitude2: (.value.amplitude2 // $defaults.amplitude2 // 1000),
                period2: (.value.period2 // $defaults.period2 // (600 + .key)),
                gas: (
                    (.value.gas // $defaults.gas // "0untrn")
                    | capture("(?<amount>[0-9]+)(?<denom>.+)")
                    | ([((.amount | tonumber) / '$bot_count' | floor), .denom] | join(""))
                ),
            },
        })
    '
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
"$( echo "$docker_env" | jq '.Config' | tr -d '\r' | tr '\n' ' ' )"
y
EOF
}

createUserKey() {
    person="$1"
    mnemonic="$2"
    # add only if user is not yet saved
    # note: when the keys list is empty it will cause a jq error: `parse error: Invalid numeric literal at line 1, column 3`
    #       this is because the empty list returns
    keys_list=$( neutrond keys list --output json )
    if [ "$keys_list" = "No records were found in keyring" ]
    then
        has_key="0"
    else
        has_key=$( echo "$keys_list" | jq -r 'map(select(.name == "'$person'")) | length' || echo "0" )
    fi
    if [ "$has_key" -eq "0" ]
    then
        # script will exit if it errors here
        echo "$mnemonic" | neutrond keys add $person --recover > /dev/stderr
    fi
}

createUser() {
    docker_env="${1:-"$( getDockerEnv )"}"
    # create mnenomic from container Env (without line breaks)
    mnemonic=$( createMnemonic "$docker_env" )
    echo "mnemonic: $mnemonic" > /dev/stderr
    # add the new account under hostname
    person="$( echo "$docker_env" | jq -r '.Config.Hostname' )"
    echo "creating user: $person" > /dev/stderr
    # add only if user is not yet saved
    createUserKey "$person" "$mnemonic"
    echo "$person";
}

getFaucetWallet() {
    docker_env="${1:-"$( getDockerEnv )"}"
    # if mnenomics are defined then take wallet from a given mnemonic
    MNEMONICS="${MNEMONICS:-"$MNEMONIC"};"
    mnemonics_array=()
    i=1
    # accept line breaks, tabs, semicolons, commas, and multiple spaces as delimiters
    mnemonics_json=$( echo "\"$MNEMONICS\"" | tr '\r\n;,' '  ' | jq -r 'split("  +"; "g")' )
    mnemonics_json_count=$( echo "$mnemonics_json" | jq -r 'length' )
    for (( i=0; i<$mnemonics_json_count; i++ ))
    do
        mnemonic=$( echo "$mnemonics_json" | jq -r ".[$i]"  )
        # do not include duplicates
        if [ ! -z "$mnemonic" ] && [[ ! " ${mnemonics_array} " =~ " ${mnemonic} " ]]
        then
            mnemonics_array+=( "$mnemonic" )
        fi
    done

    # pick the mnenomic to use out of the mnemonics array
    bot_number="$( getBotNumber "$docker_env" )"
    bot_index=$(( ($bot_number - 1) % ${#mnemonics_array[@]} ))
    mnemonic=$(echo "${mnemonics_array[$bot_index]}")
    if [ ! -z "$mnemonic" ]
    then
        # add the faucet account
        createUserKey "faucet" "$mnemonic"
        echo "$person";
    else
        echo "at least one mnemonic should be provided in MNEMONIC/MNEMONICS"
        exit 1
    fi
}

getFundedUserBalances() {
    # add the new account if needed
    person="${1:-"$( createUser "$docker_env" )"}"
    address="$( neutrond keys show $person -a )"
    # wait for the user to be funded
    try_count=20
    for (( i=1; i<=$try_count; i++ ))
    do
        balances=$( neutrond query bank balances "$address" --limit 100 --count-total --output json )
        token_count=$( echo "$balances" | jq -r '.balances | length' )
        if [ "$token_count" -gt 0 ]
        then
            echo "funding: user $person is funded!" > /dev/stderr
            echo "$balances"
            return 0
        else
            echo "funding: user $person has no tokens, waiting for funds (tried $i times)..." > /dev/stderr
            sleep 3
        fi
    done
    echo "funding error: user $person has no tokens, waited $try_count times with no response" > /dev/stderr
    exit 1
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
