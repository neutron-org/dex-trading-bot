# get base image of neutrond binary to use in trade script
FROM neutron-node as neutrond-binary


# allow this container to contact other Docker containers through the docker CLI
FROM docker:24.0.5-cli

# add additional dependencies for the testnet scripts
RUN apk add bash curl grep openssl jq;

COPY --from=neutrond-binary /go/bin/neutrond /usr/bin

WORKDIR /workspace/neutron
COPY scripts /workspace/neutron/scripts

CMD bash ./scripts/run_trade_bot.sh
