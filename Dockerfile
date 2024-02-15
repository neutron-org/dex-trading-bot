# allow this container to contact other Docker containers through the docker CLI
FROM docker:24.0.5-cli

# add additional dependencies for the testnet scripts
RUN apk add bash curl grep openssl jq;

WORKDIR /workspace/neutron
COPY scripts /workspace/neutron/scripts

CMD bash ./scripts/run_trade_bot.sh
