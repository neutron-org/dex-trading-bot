#!/bin/bash
set -e

SCRIPTPATH="$( dirname "$(readlink "$BASH_SOURCE" || echo "$BASH_SOURCE")" )"

# wait for chain to be ready
token_config_array=$( bash $SCRIPTPATH/helpers.sh getTokenConfigArray )

# check that token config is set, if it is not set, there is nothing to do
token_config_length=$( echo ${token_config_array:-"[]"} | jq -r 'length' )
if [ ! "${token_config_length:-0}" -gt "0" ]
then
    echo "incomplete TOKEN_CONFIG: at least one valid pair is required to trade"
    exit 1
fi;

# wait for chain to be ready
bash $SCRIPTPATH/check_chain_status.sh

docker_env="$( bash $SCRIPTPATH/helpers.sh getDockerEnv )"
bot_number="$( bash $SCRIPTPATH/helpers.sh getBotNumber "$docker_env" )"

# fund all bots from bot 1
if [ "$bot_number" -eq "1" ]
then
    # get funding user
    funder=$( bash $SCRIPTPATH/helpers.sh getFaucetWallet "$docker_env" )

    # gather the users of each bot container, one by one
    docker_envs="$( bash $SCRIPTPATH/helpers.sh getDockerEnvs "$docker_env" )"
    docker_envs_count="$( echo "$docker_envs" | jq -r 'length' )"
    user_addresses_array=()
    for (( i=0; i<$docker_envs_count; i++ ))
    do
        docker_env="$( echo "$docker_envs" | jq ".[$i]" )"

        # get fundee user
        user=$( bash $SCRIPTPATH/helpers.sh createUser "$docker_env"  )
        user_addresses_array+=( "$( neutrond keys show $user -a )" )
    done

    # find the amount of tokens to given all accounts
    tokens=$( bash $SCRIPTPATH/helpers.sh getTokenConfigTokensRequired )

    # multi-send to multiple users ($tokens amount is sent to each user)
    send_or_multi_send="send"
    if [ "${#user_addresses_array[@]}" -gt 1 ]
    then
        send_or_multi_send="multi-send"
    fi
    response=$(
        neutrond tx bank $send_or_multi_send \
            "$( neutrond keys show $funder -a )" \
            "${user_addresses_array[@]}" \
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
        tx_result=$( bash $SCRIPTPATH/helpers.sh waitForTxResult "$API_ADDRESS" "$tx_hash" )
        if [ "$( echo "$tx_result" | jq -r '.tx_response.code' )" -eq "0" ]
        then
            echo "funded users: ${user_addresses_array[@]} with tokens $tokens"
        else
            echo "funding user error (code: $( echo $response | jq -r '.tx_response.code' )): $( echo $response | jq -r '.tx_response.raw_log' )" > /dev/stderr
        fi
    else
        echo "funding user error (code: $( echo $response | jq -r '.code' )): $( echo $response | jq -r '.raw_log' )" > /dev/stderr
    fi
fi
