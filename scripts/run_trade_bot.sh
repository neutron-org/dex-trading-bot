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

# add function to check when the script should finish
end_epoch=$( bash $SCRIPTPATH/helpers.sh getBotEndTime )
function check_duration {
  extra_time="${1:-0}"
  if [ ! -z $end_epoch ] && [ $end_epoch -lt $(( $EPOCHSECONDS + $extra_time )) ]
  then
    echo "duration reached";
  fi
}

TRADE_FREQUENCY_SECONDS="${TRADE_FREQUENCY_SECONDS:-60}"

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

  echo "... loop will delay for: $delay"
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
    token0_initial_deposit_amount="$(( $token0_total_amount / ($bot_count + 1) / 2 ))"
    token1_initial_deposit_amount="$(( $token1_total_amount / ($bot_count + 1) / 2 ))"
    # the amount of a single this is the deposit amount spread across the ticks on one side
    token0_single_tick_deposit_amount="$(( $token0_initial_deposit_amount / $tick_count_on_each_side ))"
    token1_single_tick_deposit_amount="$(( $token1_initial_deposit_amount / $tick_count_on_each_side ))"

    # determine the new current price goal
    # approximate price with sine curves of given amplitude and period
    # by default: macro curve (1) oscillates over hours / micro curve (2) oscillates over minutes
    current_price=$( \
      echo " $price_index + $amplitude1*s($EPOCHSECONDS / $period1 * $two_pi) + $amplitude2*s($EPOCHSECONDS / $period2 * $two_pi) " \
      | bc -l \
      | awk '{printf("%d\n",$0+0.5)}' \
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
    goal_price=$(( $current_price + $deviation ))

    # - make a swap to get to current price
    echo "calculating: a swap on the pair '$token0' and '$token1'..."

    # first, find the reserves of tokens that are outside the desired price
    # then swap those reserves
    echo "making query: of current '$token0' ticks"
    reserves0=$( \
      neutrond query dex list-tick-liquidity "$token0<>$token1" "$token0" --output json --limit 100 \
      | jq "[.tick_liquidity[].pool_reserves | select(.key.tick_index_taker_to_maker != null) | select((.key.tick_index_taker_to_maker | tonumber) > ($goal_price * -1)) | if .reserves_maker_denom == null then 0 else .reserves_maker_denom end | tonumber] | add as \$sum | if \$sum == null then 0 else \$sum end" \
    )
    # convert back to decimal notation with float precision
    reserves0=$( printf '%.0f\n' "$reserves0" )
    # use bc for aribtrary precision math comparison (non-zero result evals true)
    if (( $(bc <<< "$reserves0 > 0") ))
    then
      echo "making place-limit-order: '$token1' -> '$token0'"
      balance="$( neutrond query bank balances $address --denom $token1 --output json | jq -r '.amount' )"
      if [ "$balance" -gt "0" ]
      then
        response="$(
          neutrond tx dex place-limit-order \
          `# receiver` \
          $address \
          `# token in` \
          $token1 \
          `# token out` \
          $token0 \
          `# tickIndexInToOut (note: simply using the max tick limit so the limit is not reached)` \
          "[$(( $goal_price * -1 ))]" \
          `# amount in: allow up to the denom balance to be traded, so we can reach the tick limit` \
          "$balance" \
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
    else
      echo "making query: of current '$token1' ticks"
      reserves1=$( \
        neutrond query dex list-tick-liquidity "$token0<>$token1" "$token1" --output json --limit 100 \
        | jq "[.tick_liquidity[].pool_reserves | select(.key.tick_index_taker_to_maker != null) | select((.key.tick_index_taker_to_maker | tonumber) < $goal_price) | if .reserves_maker_denom == null then 0 else .reserves_maker_denom end | tonumber] | add as \$sum | if \$sum == null then 0 else \$sum end" \
      )
      # convert back to decimal notation with float precision
      reserves1=$( printf '%.0f\n' "$reserves1" )
      if (( $(bc <<< "$reserves1 > 0") ))
      then
        echo "making place-limit-order: '$token0' -> '$token1'"
        balance="$( neutrond query bank balances $address --denom $token0 --output json | jq -r '.amount' )"
        if [ "$balance" -gt "0" ]
        then
          response="$(
            neutrond tx dex place-limit-order \
            `# receiver` \
            $address \
            `# token in` \
            $token0 \
            `# token out` \
            $token1 \
            `# tickIndexInToOut (note: simply using the max tick limit so the limit is not reached)` \
            "[$(( $goal_price * 1 ))]" \
            `# amount in: allow up to the denom balance to be traded, so we can reach the tick limit` \
            "$balance" \
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
    fi

    # check if duration has been reached
    if [ ! -z "$( check_duration )" ]
    then
      break
    fi

    # - replace the end pieces of liquidity with values closer to the current price

    # determine new indexes close to the current price (within deposit accuracy, but not within swap accuracy)
    new_index0=$( get_integer_between $(( $current_price - $deposit_index_accuracy )) $(( $current_price - $swap_index_accuracy )) )
    new_index1=$( get_integer_between $(( $current_price + $deposit_index_accuracy )) $(( $current_price + $swap_index_accuracy )) )

    # add these extra ticks to prevent swapping though all ticks errors
    # we deposit first to lessen the cases where we have entirely one-sided liquidity
    echo "making deposit: '$token0' + '$token1'"
    neutrond tx dex deposit \
      `# receiver` \
      $address \
      `# token-a` \
      $token0 \
      `# token-b` \
      $token1 \
      `# list of amount-0` \
      "$token0_single_tick_deposit_amount,0" \
      `# list of amount-1` \
      "0,$token1_single_tick_deposit_amount" \
      `# list of tick-index` \
      "[$new_index0,$new_index1]" \
      `# list of fees` \
      "$( get_joined_array 2 get_fee "$fees" )" \
      `# disable_autoswap` \
      false,false \
      `# options` \
      --from $person --yes --output json --broadcast-mode sync --gas auto --gas-adjustment $GAS_ADJUSTMENT --gas-prices $GAS_PRICES \
      | jq -r '.txhash' \
      | xargs -I{} bash $SCRIPTPATH/helpers.sh waitForTxResult $API_ADDRESS "{}" \
      | jq -r '"[ tx code: \(.tx_response.code) ] [ tx hash: \(.tx_response.txhash) ]"' \
      | xargs -I{} echo "{} deposited: new close-to-price ticks $new_index0, $new_index1"

    # check if duration has been reached
    if [ ! -z "$( check_duration )" ]
    then
      break
    fi

    # find reserves to withdraw
    echo "making query: finding '$token0', '$token1' deposits to withdraw"
    user_deposits=$( bash $SCRIPTPATH/helpers.sh getAllItemsOfPaginatedAPIList "/neutron/dex/user/deposits/$address" "deposits" )
    sorted_user_deposits=$(
      echo "$user_deposits" | jq "[.deposits[] | select(.pair_id.token0 == \"$token0\") | select(.pair_id.token1 == \"$token1\")] | sort_by((.center_tick_index | tonumber))"
    )

    last_liquidity0=$( echo "$sorted_user_deposits" | jq '.[0]' )
    fee0=$( echo "$last_liquidity0" | jq -r '.fee' )
    index0=$( echo "$last_liquidity0" | jq -r '.center_tick_index' )
    reserves0=$( echo "$last_liquidity0" | jq -r '.shares_owned' )

    last_liquidity1=$( echo "$sorted_user_deposits" | jq '.[-1]' )
    fee1=$( echo "$last_liquidity1" | jq -r '.fee' )
    index1=$( echo "$last_liquidity1" | jq -r '.center_tick_index' )
    reserves1=$( echo "$last_liquidity1" | jq -r '.shares_owned' )

    # withdraw the end values
    if [ ! -z $reserves0 ] && [ ! -z $reserves1 ]
    then
      echo "making withdrawal: '$token0' + '$token1'"
      neutrond tx dex withdrawal \
        `# receiver` \
        $address \
        `# token-a` \
        $token0 \
        `# token-b` \
        $token1 \
        `# list of shares-to-remove` \
        "$reserves0,$reserves1" \
        `# list of tick-index (adjusted to center tick)` \
        "[$index0,$index1]" \
        `# list of fees` \
        "$fee0,$fee1" \
        `# options` \
        --from $person --yes --output json --broadcast-mode sync --gas auto --gas-adjustment $GAS_ADJUSTMENT --gas-prices $GAS_PRICES \
        | jq -r '.txhash' \
        | xargs -I{} bash $SCRIPTPATH/helpers.sh waitForTxResult $API_ADDRESS "{}" \
        | jq -r '"[ tx code: \(.tx_response.code) ] [ tx hash: \(.tx_response.txhash) ]"' \
        | xargs -I{} echo "{} withdrew:  end ticks $index0, $index1"
    fi

  done

done

echo "TRADE_DURATION_SECONDS has been reached";
echo "exiting trade script"
