#!/bin/bash
set -e

SCRIPTPATH="$( dirname "$(readlink "$BASH_SOURCE" || echo "$BASH_SOURCE")" )"

# wait for chain to be ready
bash $SCRIPTPATH/check_chain_status.sh

docker_env="$( bash $SCRIPTPATH/helpers.sh getDockerEnv )"
bot_number="$( bash $SCRIPTPATH/helpers.sh getBotNumber "$docker_env" )"

# get funded user
user=$( bash $SCRIPTPATH/helpers.sh createUser "$docker_env"  )
address="$( neutrond keys show $user -a )"

# withdraw the users pools if asked for
if [ ! -z "$ON_EXIT_WITHDRAW_POOLS" ]
then
    echo "will withdraw pools before exiting"
    # get all user's dex deposits
    deposits=$( bash $SCRIPTPATH/helpers.sh getAllItemsOfPaginatedAPIList "/neutron/dex/user/deposits/$address" "deposits" )
    if [ "$( echo "$deposits" | jq -r '.deposits | length' )" ]
    then
        # collect unique pair_ids
        pair_tokens=$( echo "$deposits" | jq -r '.deposits | unique_by([.pair_id.token0, .pair_id.token1] | join(",")) | map(.pair_id)' )
        pair_tokens_count=$( echo "$pair_tokens" | jq -r 'length' )

        # withdraw pools from each token pair
        for (( pair_token_index=0; pair_token_index<$pair_tokens_count; pair_token_index++ ))
        do
            token0=$( echo "$pair_tokens" | jq -r ".[$pair_token_index].token0" )
            token1=$( echo "$pair_tokens" | jq -r ".[$pair_token_index].token1" )
            token_pair_deposits=$( echo "$deposits" | jq -r "
                .deposits
                | map(
                    select(.pair_id.token0 == \"$token0\")
                    | select(.pair_id.token1 == \"$token1\")
                )
            ")
            fees=$( echo "$token_pair_deposits" | jq -r 'map(.fee) | join(",")' )
            indexes=$( echo "$token_pair_deposits" | jq -r 'map(.center_tick_index) | join(",")' )
            reserves=$( echo "$token_pair_deposits" | jq -r 'map(.shares_owned) | join(",")' )

            echo "making withdrawal: '$token0' + '$token1'"
            response=$(
                neutrond tx dex withdrawal \
                    `# receiver` \
                    $address \
                    `# token-a` \
                    $token0 \
                    `# token-b` \
                    $token1 \
                    `# list of shares-to-remove` \
                    "$reserves" \
                    `# list of tick-index (adjusted to center tick)` \
                    "[$indexes]" \
                    `# list of fees` \
                    "$fees" \
                    `# options` \
                    --from $user --yes --output json --broadcast-mode sync --gas auto --gas-adjustment $GAS_ADJUSTMENT --gas-prices $GAS_PRICES
            )
            if [ "$( echo $response | jq -r '.code' )" -eq "0" ]
            then
                tx_hash=$( echo $response | jq -r '.txhash' )
                # get tx result for msg
                tx_result=$( bash $SCRIPTPATH/helpers.sh waitForTxResult "$API_ADDRESS" "$tx_hash" )
                if [ "$( echo "$tx_result" | jq -r '.tx_response.code' )" -eq "0" ]
                then
                    ids=$( echo "$token_pair_deposits" | jq -r 'map([.center_tick_index, .fee] | join("/")) | join(",")' )
                    echo "withdrew: ticks $ids"
                else
                    echo "withdrawing error (code: $( echo $response | jq -r '.tx_response.code' )): $( echo $response | jq -r '.tx_response.raw_log' )" > /dev/stderr
                fi
            else
                echo "withdrawing error (code: $( echo $response | jq -r '.code' )): $( echo $response | jq -r '.raw_log' )" > /dev/stderr
            fi
        done
    fi
fi

# check if user should refund the optional faucet
# get funding user
funder=$( bash $SCRIPTPATH/helpers.sh getFaucetWallet || echo "" )
if [ ! -z "$funder" ]
then
    # get all balances
    balances=$( bash $SCRIPTPATH/helpers.sh getAllItemsOfPaginatedAPIList "/cosmos/bank/v1beta1/balances/$address" "balances" )

    # select non-pool tokens to return but subtract a gas fee to use from untrn
    gas="200000"
    amounts=$( echo "$balances" | jq -r '
        .balances
        | map(
            select(.denom | match("^(?!neutron/pool)"))
            | if .denom == "untrn" then ({ amount: ((.amount | tonumber) - '"$gas"' | tostring), denom: .denom }) else . end
            | [.amount, .denom]
            | add
        )
        | join(",")
    ' )

    # return funds only if there are amounts to return
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
                --gas $gas \
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
                echo "refunded users: $funder with tokens $amounts from $user"
            else
                echo "refunding user error (code: $( echo $response | jq -r '.tx_response.code' )): $( echo $response | jq -r '.tx_response.raw_log' )" > /dev/stderr
            fi
        else
            echo "refunding user error (code: $( echo $response | jq -r '.code' )): $( echo $response | jq -r '.raw_log' )" > /dev/stderr
        fi
    elif [ ! -z "$funder" ]
    then
        echo "refunding user warning: $user has no tokens to refund to $funder"
    fi
fi

echo "final user account state: $( neutrond query bank balances "$address" --output json )"

# wait for other bots to refund the funder
bash $SCRIPTPATH/helpers.sh waitForAllBotsToSynchronizeToStage faucet_refunded 3
# wait for other bots to print their sync messages
sleep 3
