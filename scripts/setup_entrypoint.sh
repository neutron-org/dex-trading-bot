#!/bin/bash

# Trap SIGTERM
trap 'true' SIGTERM

# Setup env
bash scripts/setup_fund_users.sh
setup_error_code="$?"

# if setup completed fine then do command
if [ "$setup_error_code" -eq "0" ]
then
    # Execute command
    "${@}" &

    # Wait
    wait $!
    command_error_code="$?"

else
    # let user know they probably had a JSON parse error
    echo "setup failed (error code: $setup_error_code)"
fi

# Cleanup: any cleanup steps can go here

# return either error code
exit $(( ${command_error_code:-0} + $setup_error_code ))
