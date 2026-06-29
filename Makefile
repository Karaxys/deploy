COMPOSE_FILE ?= compose/dev/docker-compose.yml
ENV_FILE     ?= .env

COMPOSE = docker compose --env-file $(ENV_FILE) -f $(COMPOSE_FILE)

.PHONY: up down restart ps logs smoke config pull build \
        up-monitoring up-vulnerable-api up-all \
        clean prune

# ── Core stack ────────────────────────────────────────────────────────────────
up:
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart

ps:
	$(COMPOSE) ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

logs:
	$(COMPOSE) logs -f --tail=200

config:
	$(COMPOSE) config

pull:
	$(COMPOSE) pull

build:
	$(COMPOSE) build

# ── Optional profiles ─────────────────────────────────────────────────────────
up-monitoring:
	$(COMPOSE) --profile monitoring up -d --build

up-vulnerable-api:
	$(COMPOSE) --profile vulnerable-api up -d

up-all:
	$(COMPOSE) --profile monitoring --profile vulnerable-api up -d --build

# ── Smoke test ────────────────────────────────────────────────────────────────
smoke:
	./scripts/smoke-test.sh

# ── Cleanup ───────────────────────────────────────────────────────────────────
clean:
	$(COMPOSE) down --remove-orphans

prune:
	$(COMPOSE) down --volumes --remove-orphans
