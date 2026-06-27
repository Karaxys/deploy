COMPOSE_FILE ?= compose/dev/docker-compose.yml
ENV_FILE ?= .env

COMPOSE = docker compose --env-file $(ENV_FILE) -f $(COMPOSE_FILE)

.PHONY: up down restart ps logs smoke config pull build

up:
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail=200

smoke:
	./scripts/smoke-test.sh

config:
	$(COMPOSE) config

pull:
	$(COMPOSE) pull

build:
	$(COMPOSE) build
