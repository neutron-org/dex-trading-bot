# Use neutron binary version given through version number or heighliner image
# eg. passing a locally made heighliner image as NEUTRON_IMAGE
ARG NEUTRON_VERSION
# Use Heighliner build by default to get around building for correct platform issue
# as Heighliner build support multiple platforms. More details in commit message
ARG NEUTRON_IMAGE=ghcr.io/strangelove-ventures/heighliner/neutron:${NEUTRON_VERSION}

FROM "$NEUTRON_IMAGE" as neutrond-binary

# allow this container to contact other Docker containers through the docker CLI
FROM docker:24.0.5-cli

# add additional dependencies for the testnet scripts
RUN apk add bash curl grep openssl jq;

COPY --from=neutrond-binary /bin/neutrond /usr/bin

WORKDIR /workspace/neutron
COPY scripts /workspace/neutron/scripts

CMD bash ./scripts/run_trade_bot.sh
