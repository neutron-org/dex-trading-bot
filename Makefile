# this file is based on https://github.com/neutron-org/neutron-integration-tests/blob/dd5e0cf609432c970ba432a84eb53bcfef961652/setup/Makefile

REPOS_DIR ?= ./repos
SETUP_DIR ?= $(REPOS_DIR)/neutron-integration-tests/setup
COMPOSE ?= docker-compose
NEUTRON_VERSION ?= v2.0.0
GAIA_VERSION ?= v14.1.0


# --- repo init commands ---

init-dir:
ifeq (,$(wildcard $(REPOS_DIR)))
	mkdir $(REPOS_DIR)
endif

init-neutron:
ifeq (,$(wildcard $(REPOS_DIR)/neutron))
	cd $(REPOS_DIR) && git clone -b $(NEUTRON_VERSION) https://github.com/neutron-org/neutron.git
else
	cd $(REPOS_DIR)/neutron && git fetch origin $(NEUTRON_VERSION) && git checkout $(NEUTRON_VERSION)
endif

init-hermes:
ifeq (,$(wildcard $(REPOS_DIR)/neutron-integration-tests))
	cd $(REPOS_DIR) && git clone https://github.com/neutron-org/neutron-integration-tests.git
else
	cd $(REPOS_DIR)/neutron-integration-tests && git pull
endif

init-relayer:
ifeq (,$(wildcard $(REPOS_DIR)/neutron-query-relayer))
	cd $(REPOS_DIR) && git clone https://github.com/neutron-org/neutron-query-relayer.git
else
	cd $(REPOS_DIR)/neutron-query-relayer && git pull
endif

init-gaia:
ifeq (,$(wildcard $(REPOS_DIR)/gaia))
	cd $(REPOS_DIR) && git clone -b $(GAIA_VERSION) https://github.com/cosmos/gaia.git
else
	cd $(REPOS_DIR)/gaia && git fetch origin $(GAIA_VERSION) && git checkout $(GAIA_VERSION)
endif

init-all: init-dir init-neutron init-hermes init-relayer init-gaia


# --- docker build commands ---

build-gaia: init-dir init-gaia
	@docker buildx build --load --build-context app=$(REPOS_DIR)/gaia --build-context setup=$(REPOS_DIR)/neutron/network -t gaia-node -f $(SETUP_DIR)/dockerbuilds/Dockerfile.gaia --build-arg BINARY=gaiad .

build-neutron: init-dir init-neutron
	cd $(REPOS_DIR)/neutron && $(MAKE) build-docker-image

build-hermes: init-dir init-hermes
	cd $(SETUP_DIR) && $(MAKE) build-hermes

build-relayer: init-dir init-relayer
	cd $(REPOS_DIR)/neutron-query-relayer && $(MAKE) build-docker

build-all: init-all build-gaia build-neutron build-hermes build-relayer


# --- cosmopark commands from neutron-integrated-tests repo ---

start-cosmopark: build-neutron build-relayer
	@$(COMPOSE) -f $(SETUP_DIR)/docker-compose.yml up -d

start-cosmopark-no-rebuild:
	@$(COMPOSE) -f $(SETUP_DIR)/docker-compose.yml up -d

stop-cosmopark:
	@$(COMPOSE) -f $(SETUP_DIR)/docker-compose.yml down -t0 --remove-orphans -v

start-neutron-node:
	@$(COMPOSE) -f $(SETUP_DIR)/docker-compose.yml up neutron-node

clean:
	@echo "Removing previous testing data"
	-@docker volume rm neutron-testing-data


# --- new docker compose network commands ---

build-trade-bot:
	@$(COMPOSE) build

start-trade-bot: build-trade-bot
	@$(COMPOSE) up

stop-trade-bot:
	@$(COMPOSE) down -t0 --remove-orphans -v

test-trade-bot: export TRADE_DURATION_SECONDS ?= 60
test-trade-bot: stop-trade-bot build-trade-bot
	@$(COMPOSE) up --abort-on-container-exit || true
	$(MAKE) stop-trade-bot
