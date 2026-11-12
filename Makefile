
COMPOSE := docker compose -f deploy/compose.yaml

.PHONY: dev-deps dev-deps-down db-reset psql redis-cli

# Start Postgres + Redis for daily development; waits until both are healthy.
dev-deps:
	$(COMPOSE) up -d --wait

# Stop them (data is kept in the volume).
dev-deps-down:
	$(COMPOSE) down

# Wipe the database completely and start fresh.
db-reset:
	$(COMPOSE) down -v
	$(COMPOSE) up -d --wait

# Open a SQL prompt inside the Postgres container.
psql:
	$(COMPOSE) exec postgres psql -U huddle -d huddle

# Open a Redis prompt inside the Redis container.
redis-cli:
	$(COMPOSE) exec redis redis-cli