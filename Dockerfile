ARG NEUTRON_VERSION=latest

# the neutron binary image is typically built on amd64 (but may be changed)
# see: https://github.com/neutron-org/neutron/blob/v5.0.0-rc0/Makefile#L107-L122
ARG BUILDPLATFORM=amd64

# optionally specify a difference image to get the binary from
ARG NEUTRON_IMAGE=neutron-${BUILDPLATFORM}:${NEUTRON_VERSION}

# make build platform consistent across images to avoid docker.io lookup error
# see: https://stackoverflow.com/questions/20481225/how-can-i-use-a-local-image-as-the-base-image-with-a-dockerfile#69798220
FROM --platform=${BUILDPLATFORM} ${NEUTRON_IMAGE} AS neutrond-binary

# allow this container to contact other Docker containers through the docker CLI
FROM --platform=${BUILDPLATFORM} docker:27.3.1-cli

# add additional dependencies for the testnet scripts
RUN apk add bash curl grep jq;

COPY --from=neutrond-binary /bin/neutrond /usr/bin

WORKDIR /workspace/neutron
COPY scripts /workspace/neutron/scripts

CMD bash ./scripts/run_trade_bot.sh
