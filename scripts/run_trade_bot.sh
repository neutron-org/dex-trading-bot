#!/bin/bash
set -e

# make script path consistent
SCRIPTPATH="$( dirname "$(readlink "$BASH_SOURCE" || echo "$BASH_SOURCE")" )"

# wait for chain to be ready
bash $SCRIPTPATH/check_chain_status.sh

# define the person to trade with as the "trader" account
person=$( bash $SCRIPTPATH/helpers.sh createUser )
address=$( neutrond keys show "$person" -a )
# wait for the user to be funded
bash $SCRIPTPATH/helpers.sh getFundedUserBalances $person

# add some helper functions to generate chain CLI args
function join_with_comma {
  local IFS=,
  echo "$*"
}

function repeat_with_comma {
  value=$1
  count=$2
  repeated=()
  for (( i=0; i<$count; i++ ))
  do
    repeated+=( $value )
  done
  join_with_comma "${repeated[@]}"
}

function get_joined_array {
  count=$1
  values=()
  for (( i=0; i<$count; i++ ))
  do
    values+=( `$2 $i "${values[*]}" "$3" "$4"` )
  done
  echo "$( join_with_comma "${values[@]}" )"
}

function get_integer_between {
  lower=${1:-0}
  upper=${2:-1}
  difference=$(( $upper - $lower ))
  # choose a random number: $lower <= $result < $upper
  echo "$(( $lower + $RANDOM % $difference ))"
}

function get_unique_integers_between {
  array_index=$1
  array_string=$2
  lower=$3
  upper=$4
  # choose a random number: $lower <= $result < $upper
  result=$( get_integer_between "$lower" "$upper" )
  # pick another result if this one was already picked (within reason)
  # having duplicate indexes will cause an error message (but not an exception)
  local tries=0
  while [[ " ${array_string} " =~ " ${result} " ]] && [ $tries -lt 30 ]
  do
    result=$( get_integer_between "$lower" "$upper" )
    tries=$(( $tries + 1 ))
  done
  echo "$result"
}

function get_fee {
  array_index=$1
  array_string=$2
  fees=$3
  length=$( echo "$fees" | jq -r "length" )
  random_index=$(( $RANDOM % $length ))
  random_value=$( echo "$fees" | jq -r ".[$random_index]" )
  echo "$random_value"
}

function rounded_calculation {
  echo " $1 " | bc -l | awk '{print int($1+0.5)}'
}

# create a place to hold the tokens used state
# we will try not to spend more tokens than are agreed to in the config ENV var
declare -A tokens_available=()

# get token pair simulation configurations
bot_count=$( bash $SCRIPTPATH/helpers.sh getBotCount )
token_pair_config_array=$( bash $SCRIPTPATH/helpers.sh getTokenConfigArray )
token_pair_config_array_length=$( echo "$token_pair_config_array" | jq -r 'length' )

two_pi=$( echo "scale=8; 8*a(1)" | bc -l )

# delay bots as part of startup ramping process
start_epoch=$( bash $SCRIPTPATH/helpers.sh getBotStartTime )
sleep $(( $start_epoch - $EPOCHSECONDS > 0 ? $start_epoch - $EPOCHSECONDS : 0 ))

TRADE_FREQUENCY_SECONDS="${TRADE_FREQUENCY_SECONDS:-60}"

# add function to check when the script should finish
end_epoch=$( bash $SCRIPTPATH/helpers.sh getBotEndTime "$TRADE_FREQUENCY_SECONDS" )
function check_duration {
  extra_time="${1:-0}"
  if [ ! -z $end_epoch ]
  then
    echo "duration check: $(( $end_epoch - $EPOCHSECONDS )) seconds left to go" > /dev/stderr
    if [ $end_epoch -lt $(( $EPOCHSECONDS + $extra_time )) ]
    then
      echo "duration reached";
    fi
  fi
}

# respond to price changes forever
while true
do
  # wait a bit, maybe less than a block or enough that we don't touch a block or two
  delay=$(( $TRADE_FREQUENCY_SECONDS > 0 ? $RANDOM % $TRADE_FREQUENCY_SECONDS : 0 ))

  # check if duration will be reached
  if [ ! -z "$( check_duration $delay )" ]
  then
    break
  fi

  echo "... loop will delay for: $delay seconds"
  sleep $delay
  echo "loop: starting at $EPOCHSECONDS"

  for (( pair_index=0; pair_index<$token_pair_config_array_length; pair_index++ ))
  do
    token_pair=$( echo "$token_pair_config_array" | jq -r ".[$pair_index].pair | sort_by(.denom)" )
    token_pair_config=$( echo "$token_pair_config_array" | jq -r ".[$pair_index].config" )

    # pair simulation options
    token0=$( echo "$token_pair" | jq -r '.[0].denom' )
    token1=$( echo "$token_pair" | jq -r '.[1].denom' )
    token0_total_amount=$( echo "$token_pair" | jq -r '.[0].amount' )
    token1_total_amount=$( echo "$token_pair" | jq -r '.[1].amount' )
    tick_count=$( echo "$token_pair_config" | jq -r '.ticks' )
    tick_count_on_each_side=$(( $tick_count / 2 ))
    # convert price to price index here
    price_index=$( echo "$token_pair_config" | jq -r '((.price | log)/(1.0001 | log) | round)' )
    fees=$( echo "$token_pair_config" | jq -r '.fees' )
    rebalance_factor=$( echo "$token_pair_config" | jq -r '.rebalance_factor' )
    deposit_factor=$( echo "$token_pair_config" | jq -r '.deposit_factor' )
    swap_factor=$( echo "$token_pair_config" | jq -r '.swap_factor' )
    deposit_index_accuracy=$( echo "$token_pair_config" | jq -r '.deposit_accuracy' )
    swap_index_accuracy=$( echo "$token_pair_config" | jq -r '.swap_accuracy' )
    amplitude1=$( echo "$token_pair_config" | jq -r '.amplitude1' )
    amplitude2=$( echo "$token_pair_config" | jq -r '.amplitude2' )
    period1=$( echo "$token_pair_config" | jq -r '.period1' )
    period2=$( echo "$token_pair_config" | jq -r '.period2' )

    # calculate token amounts we will use in the initial deposit
    # the amount deposited by all bots should not be more than can be swapped by any one bot
    # eg. config 300A<>300B with 2 bots:
    #     - deposit maximum 50A,50B from each bot = total deposit 100A,100B
    #     - imagine that all of B is swapped out -->  total deposit 200A,0B
    #     - each bot has 200A,200B in reserve, enough to always swap across the total A tokens
    #     - swaps may still fail due to different token equivalence at price points not close to index 0
    # in general terms this is:
    #     - deposited = available / (bot_count+1) / 2
    #     -  reserves = available - deposited
    token0_max_initial_deposit_amount="$(( $token0_total_amount / ($bot_count + 1) / 2 ))"
    token1_max_initial_deposit_amount="$(( $token1_total_amount / ($bot_count + 1) / 2 ))"
    token0_initial_deposit_amount=$( rounded_calculation "$token0_max_initial_deposit_amount * $deposit_factor" )
    token1_initial_deposit_amount=$( rounded_calculation "$token1_max_initial_deposit_amount * $deposit_factor" )

    # the amount of a single this is the deposit amount spread across the ticks on one side
    token0_single_tick_deposit_amount="$(( $token0_initial_deposit_amount / $tick_count_on_each_side ))"
    token1_single_tick_deposit_amount="$(( $token1_initial_deposit_amount / $tick_count_on_each_side ))"

    # determine the new current price goal
    # approximate price with sine curves of given amplitude and period
    # by default: macro curve (1) oscillates over hours / micro curve (2) oscillates over minutes
    current_price=$(
      rounded_calculation \
      "$price_index + $amplitude1*s($EPOCHSECONDS / $period1 * $two_pi) + $amplitude2*s($EPOCHSECONDS / $period2 * $two_pi)"
    )

    echo "pair: $token0<>$token1 current price index is $current_price ($( echo "1.0001^$current_price" | bc -l ) $token0 per $token1)"

    # if initial ticks do not yet exist, add them so we have some liquidity to swap with
    if [ -z "${tokens_available["$pair_index-$token0"]}" ]
    then
      echo "making deposit: initial ticks for $token0 and $token1"
      # apply half of the available tokens to all tick indexes specified
      neutrond tx dex deposit \
        `# receiver` \
        $address \
        `# token-a` \
        $token0 \
        `# token-b` \
        $token1 \
        `# list of amount-0` \
        "$(
          repeat_with_comma "$token0_single_tick_deposit_amount" "$tick_count_on_each_side"
        ),$(
          repeat_with_comma "0" "$tick_count_on_each_side"
        )" \
        `# list of amount-1` \
        "$(
          repeat_with_comma "0" "$tick_count_on_each_side"
        ),$(
          repeat_with_comma "$token1_single_tick_deposit_amount" "$tick_count_on_each_side"
        )" \
        `# list of tickIndexInToOut` \
        "[$(
          get_joined_array $tick_count_on_each_side get_unique_integers_between $(( $current_price - $deposit_index_accuracy )) $current_price
        ),$(
          get_joined_array $tick_count_on_each_side get_unique_integers_between $(( $current_price + $deposit_index_accuracy )) $current_price
        )]" \
        `# list of fees` \
        "$( get_joined_array $tick_count get_fee "$fees" )" \
        `# disable_autoswap` \
        "$(repeat_with_comma "false" "$tick_count")" \
        `# options` \
        --from $person --yes --output json --broadcast-mode sync --gas auto --gas-adjustment $GAS_ADJUSTMENT --gas-prices $GAS_PRICES \
        | jq -r '.txhash' \
        | xargs -I{} bash $SCRIPTPATH/helpers.sh waitForTxResult "$API_ADDRESS" "{}" \
        | jq -r '"[ tx code: \(.tx_response.code) ] [ tx hash: \(.tx_response.txhash) ]"' \
        | xargs -I{} echo "{} deposited: initial $tick_count seed liquidity ticks"

      # commit the remainder amount of tokens to our token store
      tokens_available["$pair_index-$token0"]="$(( $token0_total_amount - $token0_initial_deposit_amount ))"
      tokens_available["$pair_index-$token1"]="$(( $token1_total_amount - $token1_initial_deposit_amount ))"
    fi

    # add some randomness into price goal (within swap_index_accuracy)
    deviation=$(( $RANDOM % ( $swap_index_accuracy * 2 ) - $swap_index_accuracy ))
    # compute goal price (and inverse gola price for inverted token pair order: token1<>token0)
    goal_price=$(( $current_price + $deviation ))
    goal_price_ratio=$( echo "1.0001^$goal_price" | bc -l )

    # - make a swap to get to current price
    echo "calculating: a swap on the pair '$token0' and '$token1'..."

    # first, find the reserves of tokens that are outside the desired price
    # then swap those reserves
    echo "making query: of current '$token0' ticks"
    first_tick0_price_ratio=$(
      neutrond query dex list-tick-liquidity "$token0<>$token1" "$token0" --output json --limit 1 \
      | jq ".tick_liquidity[0].pool_reserves.key.price_taker_to_maker"
    )
    # use bc for aribtrary precision math comparison (non-zero result evals true)
    if (( $( bc <<< "$first_tick0_price_ratio > $goal_price_ratio" ) ))
    then
      echo "making place-limit-order: '$token1' -> '$token0'"
      trade_amount="$( neutrond query bank balances $address --denom $token1 --output json | jq -r "(.amount | tonumber) * $swap_factor | floor" )"
      if [ "$trade_amount" -gt "0" ]
      then
        response="$(
          neutrond tx dex place-limit-order \
          `# receiver` \
          $address \
          `# token in` \
          $token1 \
          `# token out` \
          $token0 \
          `# tickIndexInToOut (note: this is the limit that we will swap up to, the goal)` \
          "[$(( $goal_price * -1 ))]" \
          `# amount in: allow up to a good fraction of the denom balance to be traded, to try to reach the tick limit` \
          "$trade_amount" \
          `# order type enum see: https://github.com/duality-labs/duality/blob/v0.2.1/proto/duality/dex/tx.proto#L81-L87` \
          `# use IMMEDIATE_OR_CANCEL which will has less strict checks that FILL_OR_KILL` \
          IMMEDIATE_OR_CANCEL \
          `# options` \
          --from $person --yes --output json --broadcast-mode sync --gas auto --gas-adjustment $GAS_ADJUSTMENT --gas-prices $GAS_PRICES
        )"
        # check for bad Tx submissions
        if [ "$( echo $response | jq -r '.code' )" -eq "0" ]
        then
          echo $response \
            | jq -r '.txhash' \
            | xargs -I{} bash $SCRIPTPATH/helpers.sh waitForTxResult $API_ADDRESS "{}" \
            | jq -r '"[ tx code: \(.tx_response.code) ] [ tx hash: \(.tx_response.txhash) ]"' \
            | xargs -I{} echo "{} swapped:   ticks toward target tick index of $goal_price"
        else
          echo $response | jq -r '"[ tx code: \(.code) ] [ tx raw_log: \(.raw_log) ]"' 1>&2
        fi
      else
        echo "skipping place-limit-order: '$token1' -> '$token0': not enough funds"
      fi
    fi
    # find if there are tokens to swap in the other direction
    echo "making query: of current '$token1' ticks"
    first_tick1_price_ratio=$(
      neutrond query dex list-tick-liquidity "$token0<>$token1" "$token1" --output json --limit 1 \
      | jq ".tick_liquidity[0].pool_reserves.key.price_opposite_taker_to_maker"
    )
    if (( $(bc <<< "$first_tick1_price_ratio < $goal_price_ratio") ))
    then
      echo "making place-limit-order: '$token0' -> '$token1'"
      trade_amount="$( neutrond query bank balances $address --denom $token0 --output json | jq -r "(.amount | tonumber) * $swap_factor | floor" )"
      if [ "$trade_amount" -gt "0" ]
      then
        response="$(
          neutrond tx dex place-limit-order \
          `# receiver` \
          $address \
          `# token in` \
          $token0 \
          `# token out` \
          $token1 \
          `# tickIndexInToOut (note: this is the limit that we will swap up to, the goal)` \
          "[$goal_price]" \
          `# amount in: allow up to a good fraction of the denom balance to be traded, to try to reach the tick limit` \
          "$trade_amount" \
            `# order type enum see: https://github.com/duality-labs/duality/blob/v0.2.1/proto/duality/dex/tx.proto#L81-L87` \
          `# use IMMEDIATE_OR_CANCEL which will has less strict checks that FILL_OR_KILL` \
          IMMEDIATE_OR_CANCEL \
          `# options` \
          --from $person --yes --output json --broadcast-mode sync --gas auto --gas-adjustment $GAS_ADJUSTMENT --gas-prices $GAS_PRICES
        )"
        # check for bad Tx submissions
        if [ "$( echo $response | jq -r '.code' )" -eq "0" ]
        then
          echo $response \
            | jq -r '.txhash' \
            | xargs -I{} bash $SCRIPTPATH/helpers.sh waitForTxResult $API_ADDRESS "{}" \
            | jq -r '"[ tx code: \(.tx_response.code) ] [ tx hash: \(.tx_response.txhash) ]"' \
            | xargs -I{} echo "{} swapped:   ticks toward target tick index of $goal_price"
        else
          echo $response | jq -r '"[ tx code: \(.code) ] [ tx raw_log: \(.raw_log) ]"' 1>&2
        fi
      else
        echo "skipping place-limit-order: '$token0' -> '$token1': not enough funds"
      fi
    fi

    # check if duration has been reached
    if [ ! -z "$( check_duration )" ]
    then
      break
    fi

    echo "making query: finding user's deposits to re-balance"
    user_deposits=$( bash $SCRIPTPATH/helpers.sh getAllItemsOfPaginatedAPIList "/neutron/dex/user/deposits/$address" "deposits" )
    sorted_user_deposits=$(
      echo "$user_deposits" | jq "
        .deposits
        | map(select(.pair_id.token0 == \"$token0\") | select(.pair_id.token1 == \"$token1\"))
        | sort_by(.center_tick_index | tonumber)
      "
    )
    # get approximate token deposits on each side, ordered
    token0_sorted_user_deposits=$( echo "$sorted_user_deposits" | jq "map(select((.center_tick_index | tonumber) + (.fee | tonumber) < $current_price))" )
    token1_sorted_user_deposits=$( echo "$sorted_user_deposits" | jq "map(select((.center_tick_index | tonumber) - (.fee | tonumber) > $current_price)) | reverse" )

    # calculate how many of each to rebalance (rebalance a fraction of the excessive deposits on either side)
    # note: to avoid empty errors, we "rebalance" at least one tick from each side closer to the current price goal (this could be fixed in the future)
    excess_count_filter="(length - $tick_count_on_each_side) * $rebalance_factor | floor | [., 1] | max"
    token0_excess_user_deposits_count=$( echo "$token0_sorted_user_deposits" | jq -r "$excess_count_filter" )
    token1_excess_user_deposits_count=$( echo "$token1_sorted_user_deposits" | jq -r "$excess_count_filter" )
    excess_user_deposits_count=$(( $token0_excess_user_deposits_count + $token1_excess_user_deposits_count ))

    echo "rebalance $token0 -> $token1: will move $token0_excess_user_deposits_count ticks"
    echo "rebalance $token1 -> $token0: will move $token1_excess_user_deposits_count ticks"

    # check if duration has been reached
    if [ ! -z "$( check_duration )" ]
    then
      break
    fi

    # rebalance: deposit ticks on one side to make up for the ticks that we withdraw from the other side
    # determine new indexes close to the current price (within deposit accuracy, but not within swap accuracy)
    echo "making deposit: '$token0' + '$token1'"
    neutrond tx dex deposit \
      `# receiver` \
      $address \
      `# token-a` \
      $token0 \
      `# token-b` \
      $token1 \
      `# list of amount-0` \
      "$(
        repeat_with_comma "$token0_single_tick_deposit_amount" "$token1_excess_user_deposits_count"
      ),$(
        repeat_with_comma "0" "$token0_excess_user_deposits_count"
      )" \
      `# list of amount-1` \
      "$(
        repeat_with_comma "0" "$token1_excess_user_deposits_count"
      ),$(
        repeat_with_comma "$token1_single_tick_deposit_amount" "$token0_excess_user_deposits_count"
      )" \
      `# list of tickIndexInToOut` \
      "[$(
        get_joined_array $token1_excess_user_deposits_count get_unique_integers_between $(( $current_price - $deposit_index_accuracy )) $(( $current_price - $swap_index_accuracy ))
      ),$(
        get_joined_array $token0_excess_user_deposits_count get_unique_integers_between $(( $current_price + $deposit_index_accuracy )) $(( $current_price + $swap_index_accuracy ))
      )]" \
      `# list of fees` \
      "$( get_joined_array $excess_user_deposits_count get_fee "$fees" )" \
      `# disable_autoswap` \
      "$(repeat_with_comma "false" "$excess_user_deposits_count")" \
      `# options` \
      --from $person --yes --output json --broadcast-mode sync --gas auto --gas-adjustment $GAS_ADJUSTMENT --gas-prices $GAS_PRICES \
      | jq -r '.txhash' \
      | xargs -I{} bash $SCRIPTPATH/helpers.sh waitForTxResult $API_ADDRESS "{}" \
      | jq -r '"[ tx code: \(.tx_response.code) ] [ tx hash: \(.tx_response.txhash) ]"' \
      | xargs -I{} echo "{} deposited: new close-to-price ticks ($token1_excess_user_deposits_count, $token0_excess_user_deposits_count)"

    # check if duration has been reached
    if [ ! -z "$( check_duration )" ]
    then
      break
    fi

    # find reserves to withdraw
    token0_sorted_excess_user_deposits="[]"
    if [ "$token0_excess_user_deposits_count" -gt "0" ]
    then
      token0_sorted_excess_user_deposits=$( echo "$token0_sorted_user_deposits" | jq ".[0:$token0_excess_user_deposits_count]" )
    fi

    token1_sorted_excess_user_deposits="[]"
    if [ "$token1_excess_user_deposits_count" -gt "0" ]
    then
      token1_sorted_excess_user_deposits=$( echo "$token1_sorted_user_deposits" | jq ".[0:$token1_excess_user_deposits_count]" )
    fi

    user_deposits_to_withdraw=$(
      echo "$token0_sorted_excess_user_deposits $token1_sorted_excess_user_deposits" | jq -s 'flatten'
    )
    user_deposits_to_withdraw_count=$( echo "$user_deposits_to_withdraw" | jq -r 'length' )

    # withdraw deposits
    if [ "$user_deposits_to_withdraw_count" -gt "0" ]
    then
      reserves=$( echo "$user_deposits_to_withdraw" | jq -r  '.[] | .shares_owned' )
      indexes=$( echo "$user_deposits_to_withdraw" | jq -c 'map(.center_tick_index | tonumber)' ) # indexes can be a plain array
      fees=$( echo "$user_deposits_to_withdraw" | jq -r '.[] | .fee' )

      echo "making withdrawal: '$token0' + '$token1'"
      neutrond tx dex withdrawal \
        `# receiver` \
        $address \
        `# token-a` \
        $token0 \
        `# token-b` \
        $token1 \
        `# list of shares-to-remove` \
        "$( join_with_comma $reserves )" \
        `# list of tick-index (adjusted to center tick)` \
        "$indexes" \
        `# list of fees` \
        "$( join_with_comma $fees )" \
        `# options` \
        --from $person --yes --output json --broadcast-mode sync --gas auto --gas-adjustment $GAS_ADJUSTMENT --gas-prices $GAS_PRICES \
        | jq -r '.txhash' \
        | xargs -I{} bash $SCRIPTPATH/helpers.sh waitForTxResult $API_ADDRESS "{}" \
        | jq -r '"[ tx code: \(.tx_response.code) ] [ tx hash: \(.tx_response.txhash) ]"' \
        | xargs -I{} echo "{} withdrew:  end ticks ($user_deposits_to_withdraw_count) $indexes"
    fi

  done

done

echo "TRADE_DURATION_SECONDS has been reached";
echo "exiting trade script"
