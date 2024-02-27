#!/bin/bash
set -e

SCRIPTPATH="$( dirname "$(readlink "$BASH_SOURCE" || echo "$BASH_SOURCE")" )"

# wait for chain to be ready
bash $SCRIPTPATH/check_chain_status.sh

docker_env="$( bash $SCRIPTPATH/helpers.sh getDockerEnv )"
bot_number="$( bash $SCRIPTPATH/helpers.sh getBotNumber "$docker_env" )"

# get funding user
funder=$( bash $SCRIPTPATH/helpers.sh getFaucetWallet "$docker_env" )
# get funded user
user=$( bash $SCRIPTPATH/helpers.sh createUser "$docker_env"  )
address="$( neutrond keys show $user -a )"
# get all balances
balances_paginated=()
page=1
# note: passing the given "next_key" string to the CLI doesn't seem to work
#       (acts as if next_key is an empty string), use page numbers instead
while [ -z "$balances" ] || [ ! -z "$( echo "$balances" | jq -r '.pagination.next_key // ""' )" ]
do
    balances=$( neutrond query bank balances "$address" --page "$page" --output json )
    balances_paginated+=( $balances )
    page=$(( $page + 1 ))
done
balances=$( echo "${balances_paginated[@]}" | jq -s -r 'map(.balances) | flatten' )
balances_count="$( echo "$balances" | jq -r 'length' )"

# refund funds if user has balances left
if [ "${balances_count:-"0"}" -gt "0" ]
then
    # select non-pool tokens to return
    amounts=$( echo "$balances" | jq -r 'map(select(.denom | match("^(?!neutron/pool)")) | [.amount, .denom] | add) | join(",")' )

    if [ ! -z "$amounts" ]
    then
        # send tokens back to the funder
        response=$(
            neutrond tx bank send \
                "$( neutrond keys show $user -a )" \
                "$( neutrond keys show $funder -a )" \
                $amounts \
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

            echo "refunded users: $funder with tokens $amounts from $user"
        else
            echo "refunding user error (code: $( echo $response | jq -r '.code' )): $( echo $response | jq -r '.raw_log' )" > /dev/stderr
        fi
    else
        echo "refunding user warning: $user has no tokens to refund to $funder"
    fi
fi

# wait for other bots to refund the funder
bash $SCRIPTPATH/helpers.sh waitForAllBotsToSynchronizeToStage faucet_refunded 3
# wait for other bots to print their sync messages
sleep 3
