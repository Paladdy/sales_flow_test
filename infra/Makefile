.PHONY: up down restart logs ps shell-db reset env setup-n8n demo-auto demo-manual ollama-pull ollama-test

ollama-pull:
	docker exec sales-flow-ollama ollama pull $${OLLAMA_MODEL:-llama3.2:1b}

ollama-test:
	curl -s http://localhost:$${OLLAMA_PORT:-11434}/api/tags | head -c 200
	@echo ""

env:
	@test -f .env || (cp .env.example .env && echo "Created infra/.env — update passwords and Telegram chat IDs")

up: env
	docker compose up -d
	@echo "Waiting for postgres + n8n..."
	@sleep 10
	@$(MAKE) setup-n8n

setup-n8n:
	@../scripts/setup-n8n.sh

demo-auto:
	@../scripts/demo.sh auto

demo-manual:
	@../scripts/demo.sh manual

ensure-telegram:
	@../scripts/demo.sh ensure-telegram

restart:
	docker compose restart
	@../scripts/demo.sh post-n8n || true

down:
	docker compose down

logs:
	docker compose logs -f

ps:
	docker compose ps

shell-db:
	docker compose exec postgres psql -U "$${POSTGRES_USER:-salesflow}" -d "$${POSTGRES_DB:-sales_flow}"

dashboard:
	docker compose --profile dashboard up -d

reset:
	@echo "WARNING: destroys all local data volumes"
	docker compose down -v
