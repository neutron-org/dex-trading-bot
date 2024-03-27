# this file is based on https://github.com/neutron-org/neutron-integration-tests/blob/dd5e0cf609432c970ba432a84eb53bcfef961652/setup/Makefile

REPOS_DIR ?= ./repos
SETUP_DIR ?= $(REPOS_DIR)/neutron-integration-tests/setup
DOCKER ?= docker
COMPOSE ?= docker-compose
NEUTRON_VERSION ?= v3.0.0
GAIA_VERSION ?= v15.0.0
NEUTRON_CONTAINER = $(shell $(DOCKER) ps --filter name=neutron-node -q)


# --- repo init commands ---

init-dir:
ifeq (,$(wildcard $(REPOS_DIR)))
	mkdir $(REPOS_DIR)
endif

init-neutron:
ifeq (,$(wildcard $(REPOS_DIR)/neutron))
	cd $(REPOS_DIR) && git clone -b $(NEUTRON_VERSION) https://github.com/neutron-org/neutron.git
else
	cd $(REPOS_DIR)/neutron && git fetch --tags origin $(NEUTRON_VERSION) && git checkout $(NEUTRON_VERSION)
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
	cd $(REPOS_DIR)/gaia && git fetch --tags origin $(GAIA_VERSION) && git checkout $(GAIA_VERSION)
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

clean:
	@echo "Removing previous testing data"
	-@docker volume rm neutron-testing-data


# --- new docker compose network commands ---

build-trade-bot:
	@$(COMPOSE) build --build-arg NEUTRON_VERSION=$(NEUTRON_VERSION)

start-trade-bot: build-trade-bot
	@$(COMPOSE) up

stop-trade-bot:
	@$(COMPOSE) down -t0 --remove-orphans -v

test-trade-bot: export TRADE_DURATION_SECONDS ?= 60
test-trade-bot: stop-trade-bot build-trade-bot
	@$(COMPOSE) up --abort-on-container-exit || true
	$(MAKE) stop-trade-bot

# --- after a simulation save/resume the created chain state with these commands ---

start-neutron-node: TAG_NAME ?= "latest"
start-neutron-node:
	@NEUTRON_IMAGE_TAG=$(TAG_NAME) $(COMPOSE) up neutron-node

stop-neutron-node:
	@$(COMPOSE) down neutron-node -t0 --remove-orphans -v

save-neutron-node: TAG_NAME ?= "saved"
save-neutron-node:
ifneq ($(NEUTRON_CONTAINER), undefined)
	$(DOCKER) exec $(NEUTRON_CONTAINER) mkdir /opt/neutron/backup-data
	$(DOCKER) exec $(NEUTRON_CONTAINER) cp -a /opt/neutron/data/. /opt/neutron/backup-data/
	$(DOCKER) commit $(NEUTRON_CONTAINER) "neutron-node:$(TAG_NAME)"
	$(DOCKER) exec $(NEUTRON_CONTAINER) rm -rf /opt/neutron/backup-data
else
	@echo "run container first: eg. \`make start-neutron-node\`, you can remove it after with  \`make stop-neutron-node\`"
endif

resume-neutron-node: TAG_NAME ?= "saved"
resume-neutron-node:
	$(MAKE) start-neutron-node TAG_NAME=$(TAG_NAME)
