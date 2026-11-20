COMPOSE := docker compose --env-file .env -f deploy/docker-compose.yml
PY_MOCK := mcp-servers/.venv/bin

.PHONY: help env keys up infra down clean logs ps test test-gateway test-mock token

help:  ## Show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

env:  ## Create .env from .env.example if missing
	@test -f .env || (cp .env.example .env && echo "created .env from .env.example")

keys:  ## Generate dev agent keypairs and render the Keycloak realm
	@bash scripts/gen-agent-keys.sh

up: env keys  ## Build and start the full local stack
	$(COMPOSE) up -d --build --wait

infra: env keys  ## Start only infrastructure (postgres, keycloak, opa, jaeger)
	$(COMPOSE) up -d --wait postgres keycloak opa jaeger

down:  ## Stop the stack (keeps data)
	$(COMPOSE) down

clean:  ## Stop the stack and delete volumes
	$(COMPOSE) down -v

logs:  ## Tail logs (SERVICE=name to filter)
	$(COMPOSE) logs -f $(SERVICE)

ps:  ## Show service status
	$(COMPOSE) ps

token:  ## Print decoded token claims for AGENT (default support-agent)
	@bash scripts/agent-token.sh $${AGENT:-support-agent} --claims

test: test-mock test-gateway  ## Run all tests

test-gateway:  ## Gateway tests (needs Docker for Testcontainers)
	cd gateway && ./mvnw -q test

test-mock:  ## Mock MCP server tests
	@test -x $(PY_MOCK)/pytest || (python3 -m venv mcp-servers/.venv && $(PY_MOCK)/pip install -q -e "mcp-servers[dev]")
	$(PY_MOCK)/pytest -q mcp-servers/tests
