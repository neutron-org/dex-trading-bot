#!/bin/bash
set -e

# alias neutrond to a specific Docker neutrond
SCRIPTPATH="$( dirname "$(readlink "$BASH_SOURCE" || echo "$BASH_SOURCE")" )"
neutrond() {
  bash $SCRIPTPATH/helpers.sh neutrond "$@"
}

# set which node we will talk to
CHAIN_ID="${CHAIN_ID:-$(neutrond config chain-id)}"
RPC_ADDRESS="${RPC_ADDRESS:-$(neutrond config node)}"

echo "CHAIN_ID: $CHAIN_ID"
echo "NODE: $RPC_ADDRESS"

# check docker connection status for daemon commands
echo "Docker proxy call test: neutrond version $( neutrond version )"
if [[ $? -ne 0 ]]; then
    echo "Cannot send neutrond commands to Neutron testnet"
    exit 1
fi

# check that NODE and CHAIN_ID details are correct
bash $SCRIPTPATH/check_chain_status.sh $RPC_ADDRESS $CHAIN_ID

# define the person to trade with as the "trader" account
tokens=100000000000
person=$( bash $SCRIPTPATH/helpers.sh createAndFundUser "${tokens}untrn,${tokens}uibcatom,${tokens}uibcusdc" )
address=$( neutrond keys show "$person" -a )

# add some helper functions to generate chain CLI args
count=100; # should be divisible by 4
function join_with_comma {
  local IFS=,
  echo "$*"
}
function repeat_with_comma {
  repeated=()
  for (( i=0; i<$count/2; i++ ))
  do
    repeated+=( $1 )
  done
  join_with_comma "${repeated[@]}"
}
function get_token_1_reserves_amount {
  amount=$1
  index=$2;
  # note: this calculation is inaccurate, share amount is not a pure value
  # so the reserves are not always proportional to the shares amount
  # this fact should either be considered, or tick liquidity should be tightly controlled
  # to avoid the cases where reserves are not proportional to the shares amount
  echo " $amount / (1.0001 ^ $index) " \
    | bc -l \
    | awk '{printf("%.0f\n",$0+1)}' # round up only (in case we don't create enough reserves)
}

token_pairs=( '["uibcusdc","untrn"]' '["uibcatom","uibcusdc"]' '["uibcatom","untrn"]' )

# create initial tick array outside of max price amplitude
fee_options=( 1 5 20 100 )
max_tick_index=12000
indexes0=()
indexes1=()
amounts0=()
amounts1=()
fees=()
amount=1000000000 # use a base billion tokens, assume coins have 6 decimal places
for (( i=0; i<$count/4; i++ ))
do
  index=$(( $RANDOM % $max_tick_index ))
  indexes0+=( $(( -$max_tick_index - $index )) -$index )
  indexes1+=( $index $(( $index + $max_tick_index )) )
  # calculate reserve amounts to add that will equal the same amount of shares
  amounts0+=( $amount $amount )
  amounts1+=( $( get_token_1_reserves_amount $amount $index ) )
  amounts1+=( $( get_token_1_reserves_amount $amount $(( $index + $max_tick_index )) ) )
  fee=${fee_options[$(( $RANDOM % 4 ))]}
  fees+=( $fee $fee )
done

for token_pair in ${token_pairs[@]}
do
  token0=$( echo $token_pair | jq -r .[0] )
  token1=$( echo $token_pair | jq -r .[1] )
  echo "making deposit: initial ticks for $token0 and $token1"
  # apply an amount to all tick indexes specified
  neutrond tx dex deposit \
    `# receiver` \
    $address \
    `# token-a` \
    $token0 \
    `# token-b` \
    $token1 \
    `# list of amount-0` \
    "$(repeat_with_comma "$amount"),$(repeat_with_comma "0")" \
    `# list of amount-1` \
    "$(repeat_with_comma "0"),$(join_with_comma "${amounts1[@]}")" \
    `# list of tickIndexInToOut` \
    "[$(join_with_comma "${indexes0[@]}"),$(join_with_comma "${indexes1[@]}")]" \
    `# list of fees` \
    "$(join_with_comma "${fees[@]}"),$(join_with_comma "${fees[@]}")" \
    `# disable_autoswap` \
    "$(repeat_with_comma "false"),$(repeat_with_comma "false")" \
    `# options` \
    --from $person --yes --output json --broadcast-mode sync --gas auto --gas-adjustment $GAS_ADJUSTMENT --gas-prices $GAS_PRICES \
    | jq -r '.txhash' \
    | xargs -I{} bash $SCRIPTPATH/helpers.sh waitForTxResult "$API_ADDRESS" "{}" \
    | jq -r '"[ tx code: \(.tx_response.code) ] [ tx hash: \(.tx_response.txhash) ]"' \
    | xargs -I{} echo "{} deposited: initial $count seed liquidity ticks"
done

# approximate price with sine curves of given amplitude and period
# macro curve oscillates over hours
amplitude1=10000 # in ticks
period1=3600 # in seconds
# micro curve oscillates over minutes
amplitude2=-2000 # in seconds
period2=300 # in seconds
two_pi=$( echo "scale=8; 8*a(1)" | bc -l )

TRADE_FREQUENCY_SECONDS="${TRADE_FREQUENCY_SECONDS:-60}"
max_epoch=$( [ ! -z $TRADE_DURATION_SECONDS ] && echo $(( $EPOCHSECONDS + $TRADE_DURATION_SECONDS )) || echo "" )
max_epoch_reached=false

# respond to price changes forever
while true
do
  # wait a bit, maybe less than a block or enough that we don't touch a block or two
  DELAY=$(( $TRADE_FREQUENCY_SECONDS > 0 ? $RANDOM % $TRADE_FREQUENCY_SECONDS : 0 ))
  echo ".. will delay for: $DELAY"
  sleep $DELAY

  if [ ! -z $max_epoch ] && [ $max_epoch -lt $EPOCHSECONDS ]
  then
    echo "TRADE_DURATION_SECONDS has been reached";
    exit 0
  fi

  pair_index=0
  for token_pair in ${token_pairs[@]}
  do
    pair_index+=1
    token0=$( echo $token_pair | jq -r .[0] )
    token1=$( echo $token_pair | jq -r .[1] )

    echo "calculating: a swap on the pair '$token0' and '$token1'..."

    # create random fee tier to use in this iteration
    fee=${fee_options[$(( $RANDOM % 4 ))]}

    # determine the new current price goal
    current_price=$( \
      echo " $amplitude1*s($EPOCHSECONDS / ($period1*$pair_index) * $two_pi) + $amplitude2*s($EPOCHSECONDS / $period2 * $two_pi) " \
      | bc -l \
      | awk '{printf("%d\n",$0+0.5)}' \
    )

    # add some randomness into price goal
    goal_price=$(( $current_price + $RANDOM % 1000 - 500 ))

    # - make a swap to get to current price

    # first, find the reserves of tokens that are outside the desired price
    # then swap those reserves
    echo "making query: of current '$token0' ticks"
    reserves0=$( \
      wget -q -O - $API_ADDRESS/neutron/dex/tick_liquidity/$token0%3C%3E$token1/$token0?pagination.limit=100 \
      | jq "[.tick_liquidity[].pool_reserves | select(.key.tick_index_taker_to_maker != null) | select((.key.tick_index_taker_to_maker | tonumber) > $goal_price) | if .reserves_maker_denom == null then 0 else .reserves_maker_denom end | tonumber] | add as \$sum | if \$sum == null then 0 else \$sum end" \
    )
    # convert back to decimal notation with float precision
    reserves0=$( printf '%.0f\n' "$reserves0" )
    # use bc for aribtrary precision math comparison (non-zero result evals true)
    if (( $(bc <<< "$reserves0 > 0") ))
    then
      echo "making place-limit-order: '$token1' -> '$token0'"
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
        `# amount in: we add an excess so we can reach the tick limit` \
        "$(bc <<< "$reserves0 * 100")" \
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
      echo "making query: of current '$token1' ticks"
      reserves1=$( \
        wget -q -O - $API_ADDRESS/neutron/dex/tick_liquidity/$token0%3C%3E$token1/$token1?pagination.limit=100 \
        | jq "[.tick_liquidity[].pool_reserves | select(.key.tick_index_taker_to_maker != null) | select((.key.tick_index_taker_to_maker | tonumber) < $goal_price) | if .reserves_maker_denom == null then 0 else .reserves_maker_denom end | tonumber] | add as \$sum | if \$sum == null then 0 else \$sum end" \
      )
      # convert back to decimal notation with float precision
      reserves1=$( printf '%.0f\n' "$reserves1" )
      if (( $(bc <<< "$reserves1 > 0") ))
      then
        echo "making place-limit-order: '$token0' -> '$token1'"
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
          `# amount in: we add an excess so we can reach the tick limit` \
          "$(bc <<< "$reserves1 * 100")" \
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
      fi
    fi

    # - replace the end pieces of liquidity with values closer to the current price

    # determine new indexes close to the current price
    new_index0=$(( $current_price - 1000 - $RANDOM % 1000 ))
    new_index1=$(( $current_price + 1000 + $RANDOM % 1000 ))

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
      "$amount,0" \
      `# list of amount-1` \
      "0,$( get_token_1_reserves_amount $amount $new_index1 )" \
      `# list of tick-index` \
      "[$new_index0,$new_index1]" \
      `# list of fees` \
      "$fee,$fee" \
      `# disable_autoswap` \
      false,false \
      `# options` \
      --from $person --yes --output json --broadcast-mode sync --gas auto --gas-adjustment $GAS_ADJUSTMENT --gas-prices $GAS_PRICES \
      | jq -r '.txhash' \
      | xargs -I{} bash $SCRIPTPATH/helpers.sh waitForTxResult $API_ADDRESS "{}" \
      | jq -r '"[ tx code: \(.tx_response.code) ] [ tx hash: \(.tx_response.txhash) ]"' \
      | xargs -I{} echo "{} deposited: new close-to-price ticks $new_index0, $new_index1"

    # find reserves to withdraw
    echo "making query: finding '$token0', '$token1' deposits to withdraw"
    user_deposits=$( \
      wget -q -O - $API_ADDRESS/neutron/dex/user/deposits/$( neutrond keys show $person -a )?pagination.limit=1000 \
    )
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
