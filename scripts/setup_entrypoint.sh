#!/bin/bash

# Trap SIGTERM
trap 'true' SIGTERM

# Setup env
bash scripts/setup_fund_users.sh

# Execute command
"${@}" &

# Wait
wait $!

# Cleanup
bash scripts/setup_refund_users.sh
