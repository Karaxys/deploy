COMPOSE_FILE ?= compose/dev/docker-compose.yml
ENV_FILE     ?= .env

COMPOSE = docker compose --env-file $(ENV_FILE) -f $(COMPOSE_FILE)

# ── Production / self-host stack (published images) ───────────────────────────
PROD_COMPOSE_FILE ?= compose/prod/docker-compose.yml
PROD_ENV_FILE     ?= compose/prod/.env
PROD_COMPOSE = docker compose --env-file $(PROD_ENV_FILE) -f $(PROD_COMPOSE_FILE)

.PHONY: up down restart ps logs smoke config pull build \
        up-monitoring up-vulnerable-api up-all \
        clean prune \
        init prod-up prod-down prod-restart prod-ps prod-logs prod-pull prod-config prod-monitoring

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

# ── Production / self-host (published images, no source needed) ───────────────
# First run:  make init && make prod-up
init:
	bash ./scripts/generate-secrets.sh --env-file $(PROD_ENV_FILE)

prod-up:
	@test -f $(PROD_ENV_FILE) || { echo "No $(PROD_ENV_FILE) — run 'make init' first."; exit 1; }
	$(PROD_COMPOSE) pull
	$(PROD_COMPOSE) up -d

prod-down:
	$(PROD_COMPOSE) down

prod-restart:
	$(PROD_COMPOSE) restart

prod-ps:
	$(PROD_COMPOSE) ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

prod-logs:
	$(PROD_COMPOSE) logs -f --tail=200

prod-pull:
	$(PROD_COMPOSE) pull

prod-config:
	$(PROD_COMPOSE) config

prod-monitoring:
	$(PROD_COMPOSE) --profile monitoring up -d

# ── Cleanup ───────────────────────────────────────────────────────────────────
clean:
	$(COMPOSE) down --remove-orphans

prune:
	$(COMPOSE) down --volumes --remove-orphans
