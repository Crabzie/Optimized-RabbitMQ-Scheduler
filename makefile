# Makefile for Fog Computing Scheduler

include .env
export

# Project name
PROJECT_NAME=fog-scheduler
COMPOSE_PROJECT_NAME=$(PROJECT_NAME)

# Binary names
BINARY_SCHEDULER=scheduler
BINARY_NODE=fog-node

# Default node
NODE?=1
NODE_ID?=node-$(NODE)

.PHONY: all install deps \
	up down restart clean status health \
	dev-scheduler dev-node \
	build test test-failover \
	logs logs-follow \
	rabbitmq rabbitmq-cli rabbitmq-ui rabbitmq-purge \
	redis redlis-cli redis-flush redis-clear-cluster \
	postgres postgres-cli postgres-drop-db postgres-create-db \
	debug monitor \
	help

# Quick Start
all: install up
	@echo "Setup complete!"
	@echo "  make dev-scheduler    → Run scheduler locally"
	@echo "  make dev-node NODE=1  → Run fog node locally"

install:
	@echo "Installing dependencies..."
	@$(MAKE) deps
	@go install github.com/air-verse/air@latest
	@echo "Dependencies installed"

deps:
	@go get github.com/rabbitmq/amqp091-go
	@go get github.com/redis/go-redis/v9
	@go mod tidy

	
# Service Management
up:
	@echo "Starting services sequentially..."
	@echo ""
		@echo "Step 1: Deploying stack..."
	@docker stack deploy -c compose.yml $(PROJECT_NAME)
	@docker service scale $(PROJECT_NAME)_rabbitmq1=0 $(PROJECT_NAME)_rabbitmq2=0 $(PROJECT_NAME)_rabbitmq3=0
	@sleep 10
	@echo ""
	@echo "Step 2: Waiting for PostgreSQL to be healthy..."
	@bash -c 'for i in {1..60}; do \
	  CONTAINER_ID=$$(docker ps -qf "name=$(PROJECT_NAME)_postgres"); \
	  if [ -n "$$CONTAINER_ID" ]; then \
	    if docker exec $$CONTAINER_ID pg_isready -U $(PG_USER) -d schedulerdb >/dev/null 2>&1; then \
	      echo "PostgreSQL is healthy!"; \
	      exit 0; \
	    fi; \
	  fi; \
	  printf "."; \
	  sleep 2; \
	done; \
	echo ""; \
	echo "ERROR: PostgreSQL failed to become healthy after 2 minutes"; \
	exit 1'
	@echo ""
	@echo "Step 3: Waiting for Redis to be healthy..."
	@bash -c 'for i in {1..60}; do \
	  CONTAINER_ID=$$(docker ps -qf "name=$(PROJECT_NAME)_redis"); \
	  if [ -n "$$CONTAINER_ID" ]; then \
	    if docker exec $$CONTAINER_ID redis-cli -a $(REDIS_PASS) --no-auth-warning PING >/dev/null 2>&1; then \
	      echo "Redis is healthy!"; \
	      exit 0; \
	    fi; \
	  fi; \
	  printf "."; \
	  sleep 2; \
	done; \
	echo ""; \
	echo "ERROR: Redis failed to become healthy after 2 minutes"; \
	exit 1'
	@echo ""
	@echo "Step 4: Starting RabbitMQ1 (master)..."
	@docker service scale $(PROJECT_NAME)_rabbitmq1=1
	@sleep 60
	@bash -c 'for i in {1..24}; do \
	  CONTAINER_ID=$$(docker ps -qf "name=$(PROJECT_NAME)_rabbitmq1"); \
	  if [ -n "$$CONTAINER_ID" ]; then \
	    if docker exec $$CONTAINER_ID rabbitmq-diagnostics -n rabbit@rabbitmq1 ping >/dev/null 2>&1; then \
	      echo "RabbitMQ1 ready"; \
	      exit 0; \
	    fi; \
	  fi; \
	  printf "."; \
	  sleep 10; \
	done; \
	echo ""; \
	echo "RabbitMQ1 failed to start"; \
	exit 1'
	@echo ""
	@echo "Step 5: Starting RabbitMQ2..."
	@docker service scale $(PROJECT_NAME)_rabbitmq2=1
	@sleep 60
	@bash -c 'for i in {1..24}; do \
	  CONTAINER_ID=$$(docker ps -qf "name=$(PROJECT_NAME)_rabbitmq1"); \
	  if [ -n "$$CONTAINER_ID" ]; then \
	    if docker exec $$CONTAINER_ID rabbitmqctl -n rabbit@rabbitmq1 cluster_status 2>/dev/null | grep -q "rabbit@rabbitmq2"; then \
	      echo "RabbitMQ2 joined cluster"; \
	      exit 0; \
	    fi; \
	  fi; \
	  printf "."; \
	  sleep 10; \
	done; \
	echo ""; \
	echo "RabbitMQ2 failed to join cluster"; \
	exit 1'
	@echo ""
	@echo "Step 6: Starting RabbitMQ3..."
	@docker service scale $(PROJECT_NAME)_rabbitmq3=1
	@sleep 60
	@bash -c 'for i in {1..24}; do \
	  CONTAINER_ID=$$(docker ps -qf "name=$(PROJECT_NAME)_rabbitmq1"); \
	  if [ -n "$$CONTAINER_ID" ]; then \
	    if docker exec $$CONTAINER_ID rabbitmqctl -n rabbit@rabbitmq1 cluster_status 2>/dev/null | grep -q "rabbit@rabbitmq3"; then \
	      echo "RabbitMQ3 joined cluster"; \
	      exit 0; \
	    fi; \
	  fi; \
	  printf "."; \
	  sleep 10; \
	done; \
	echo ""; \
	echo "RabbitMQ3 failed to join cluster"; \
	exit 1'
	@echo ""
	@echo "All services started!"
	@$(MAKE) status
	@$(MAKE) health

down:
	@echo "Stopping services..."
	@docker stack rm $(PROJECT_NAME)
	@sleep 10

restart:
	@$(MAKE) down
	@$(MAKE) up

clean:
	@echo "This will remove ALL data! Continue? [y/N]" && read ans && [ $${ans:-N} = y ]
	@docker stack rm $(PROJECT_NAME)
	@sleep 10
	@docker volume prune -f
	@echo "Cleanup complete"

status:
	@echo "Services"
	@docker service ls --filter "label=com.docker.stack.namespace=$(PROJECT_NAME)"
	@echo ""
	@echo "Tasks"
	@docker stack ps $(PROJECT_NAME) --format "table {{.Name}}\t{{.Node}}\t{{.CurrentState}}"
	@echo ""
	@echo "Access"
	@echo "RabbitMQ UI: http://localhost:15672 (user: $(MQ_ADMIN_USER))"
	@echo "Redis:       localhost:6379"

health:
	@echo "Service Health"
	@for svc in rabbitmq1 rabbitmq2 rabbitmq3; do \
		CONTAINER_ID=$$(docker ps -qf "name=$(PROJECT_NAME)_rabbitmq1"); \
		if [ -n "$$CONTAINER_ID" ]; then \
			if docker exec $$CONTAINER_ID rabbitmq-diagnostics -n rabbit@rabbitmq1 ping >/dev/null 2>&1; then \
				echo "$$svc: healthy"; \
			else \
				echo "$$svc: not healthy"; \
			fi; \
		else \
			echo "rabbitmq1: container not found on host manager1"; \
		fi; \
	done
	@echo ""
	@REDIS_CONTAINER=$$(docker ps -qf "name=$(PROJECT_NAME)_redis"); \
	if [ -n "$$REDIS_CONTAINER" ]; then \
		if docker exec -e REDISCLI_AUTH=$(REDIS_PASS) $$REDIS_CONTAINER redis-cli --no-auth-warning PING >/dev/null 2>&1; then \
			echo "redis: healthy"; \
		else \
			echo "redis: not healthy"; \
		fi; \
	else \
		echo "redis: container not found on host manager1"; \
	fi
	@echo ""
	@echo "Redis Coordinator"
	@ADMIN_CONTAINER=$$(docker ps -qf "name=$(PROJECT_NAME)_redis"); \
	if [ -n "$$ADMIN_CONTAINER" ]; then \
		echo -n "Members: "; \
		docker exec -e REDISCLI_AUTH=$(REDIS_PASS) $$ADMIN_CONTAINER redis-cli -h redis --no-auth-warning SMEMBERS rabbitmq:cluster:members 2>/dev/null | tr '\n' ' ' || echo "Failed to fetch members"; \
		echo ""; \
		echo -n "Master:  "; \
		docker exec -e REDISCLI_AUTH=$(REDIS_PASS) $$ADMIN_CONTAINER redis-cli -h redis --no-auth-warning GET rabbitmq:cluster:master 2>/dev/null | tr '\n' ' ' || echo "Failed to fetch master"; \
		echo ""; \
	else \
		echo "redis: container not found on host manager1"; \
	fi
	@echo ""
	@PG_CONTAINER=$$(docker ps -qf "name=$(PROJECT_NAME)_postgres"); \
	if [ -n "$$PG_CONTAINER" ]; then \
		if docker exec $$PG_CONTAINER pg_isready -U $(PG_USER) -d schedulerdb >/dev/null 2>&1; then \
			echo "postgres: healthy"; \
		else \
			echo "postgres: not healthy"; \
		fi; \
	else \
		echo "postgres: container not found on host manager1"; \
	fi

# Development
dev-scheduler:
	@echo "Starting scheduler with hot reload..."
	@cd cmd/scheduler && air

dev-node:
	@echo "Starting fog-node-$(NODE)..."
	@NODE_ID=$(NODE_ID) go run ./cmd/node/main.go

# Build
build:
	@echo "Building binaries..."
	@mkdir -p ./bin
	@go build -o ./bin/$(BINARY_SCHEDULER) ./cmd/scheduler/main.go
	@go build -o ./bin/$(BINARY_NODE) ./cmd/node/main.go
	@echo "Binaries in ./bin/"

# Testing
test:
	@echo "Running tests..."
	@go test -v ./... -race -cover -timeout 30s -count 1

test-failover:
	@echo "Testing failover recovery..."
	@echo "Force restarting rabbitmq1..."
	@docker service update --force $(PROJECT_NAME)_rabbitmq1
	@sleep 90
	@$(MAKE) rabbitmq

# Logs
logs:
	@echo "Recent Logs"
	@docker service logs $(PROJECT_NAME)_rabbitmq1 --tail 50
	@docker service logs $(PROJECT_NAME)_redis --tail 30
	@docker service logs $(PROJECT_NAME)_postgres --tail 50

logs-follow:
	@docker service logs -f $(PROJECT_NAME)_rabbitmq1 $(PROJECT_NAME)_rabbitmq2 $(PROJECT_NAME)_rabbitmq3 $(PROJECT_NAME)_redis $(PROJECT_NAME)_postgres

# RabbitMQ
rabbitmq:
	@ADMIN_CONTAINER=$$(docker ps -qf "name=$(PROJECT_NAME)_rabbitmq1"); \
	if [ -n "$$ADMIN_CONTAINER" ]; then \
		echo "Cluster Status"; \
		docker exec $$ADMIN_CONTAINER rabbitmqctl -n rabbit@rabbitmq1 cluster_status 2>/dev/null || echo "Failed to get cluster status"; \
		echo ""; \
		echo "Queues"; \
		docker exec $$ADMIN_CONTAINER rabbitmqctl -n rabbit@rabbitmq1 list_queues name messages consumers 2>/dev/null || echo "Failed to list queues"; \
		echo ""; \
		echo "Users"; \
		docker exec $$ADMIN_CONTAINER rabbitmqctl -n rabbit@rabbitmq1 list_users 2>/dev/null || echo "Failed to list users"; \
	else \
		echo "rabbitmq1: container not found on host manager1"; \
		exit 1; \
	fi

rabbitmq-cli:
	@ADMIN_CONTAINER=$$(docker ps -qf "name=$(PROJECT_NAME)_rabbitmq1"); \
	if [ -n "$$ADMIN_CONTAINER" ]; then \
		echo "Connecting to rabbitmq1 CLI..."; \
		docker exec -it $$ADMIN_CONTAINER bash || docker exec -it $$ADMIN_CONTAINER sh; \
	else \
		echo "rabbitmq1: container not found on host manager1"; \
	fi

rabbitmq-ui:
	@echo "Opening RabbitMQ Management UI..."
	@echo "URL: http://localhost:15672"
	@echo "User: $(MQ_ADMIN_USER)"
	@which xdg-open >/dev/null 2>&1 && xdg-open http://localhost:15672 || \
	which open >/dev/null 2>&1 && open http://localhost:15672 || \
	echo "Open http://localhost:15672 in your browser"

rabbitmq-purge:
	@ADMIN_CONTAINER=$$(docker ps -qf "name=$(PROJECT_NAME)_rabbitmq1"); \
	if [ -n "$$ADMIN_CONTAINER" ]; then \
		echo "Purge all queues? [y/N]" && read ans; \
		if [ "$${ans:-N}" = "y" ]; then \
			for q in tasks.high_priority tasks.normal tasks.low_priority; do \
				docker exec $$ADMIN_CONTAINER rabbitmqctl -n rabbit@rabbitmq1 purge_queue $$q --vhost /fog; \
			done; \
			echo "Queues purged"; \
		else \
			echo "Purge cancelled"; \
		fi; \
	else \
		echo "rabbitmq1: container not found on host manager1"; \
	fi

# Redis
redis:
	@ADMIN_CONTAINER=$$(docker ps -qf "name=$(PROJECT_NAME)_redis"); \
	if [ -n "$$ADMIN_CONTAINER" ]; then \
		echo "Redis Info"; \
		docker exec -e REDISCLI_AUTH=$(REDIS_PASS) $$ADMIN_CONTAINER redis-cli -h redis --no-auth-warning INFO server | grep redis_version; \
		echo ""; \
		echo "Cluster State"; \
		docker exec -e REDISCLI_AUTH=$(REDIS_PASS) $$ADMIN_CONTAINER redis-cli -h redis --no-auth-warning SMEMBERS rabbitmq:cluster:members; \
		echo ""; \
		echo "All Keys"; \
		docker exec -e REDISCLI_AUTH=$(REDIS_PASS) $$ADMIN_CONTAINER redis-cli -h redis --no-auth-warning KEYS '*'; \
	else \
		echo "redis: container not found on host manager1"; \
	fi

redis-cli:
	@ADMIN_CONTAINER=$$(docker ps -qf "name=$(PROJECT_NAME)_redis"); \
	if [ -n "$$ADMIN_CONTAINER" ]; then \
		echo "Connecting to Redis CLI..."; \
		docker exec -it -e REDISCLI_AUTH=$(REDIS_PASS) $$ADMIN_CONTAINER redis-cli -h redis --no-auth-warning; \
	else \
		echo "redis: container not found on host manager1"; \
	fi

redis-flush:
	@ADMIN_CONTAINER=$$(docker ps -qf "name=$(PROJECT_NAME)_redis"); \
	if [ -n "$$ADMIN_CONTAINER" ]; then \
		echo "Delete ALL Redis data? [y/N]" && read ans && [ $${ans:-N} = y ]; \
		docker exec -e REDISCLI_AUTH=$(REDIS_PASS) $$ADMIN_CONTAINER redis-cli -h redis --no-auth-warning FLUSHALL; \
		echo "Redis flushed"; \
	else \
		echo "redis: container not found on host manager1"; \
	fi

redis-clear-cluster:
	@ADMIN_CONTAINER=$$(docker ps -qf "name=$(PROJECT_NAME)_redis"); \
	if [ -n "$$ADMIN_CONTAINER" ]; then \
		echo "Clear cluster state? [y/N]" && read ans && [ $${ans:-N} = y ]; \
		docker exec -e REDISCLI_AUTH=$(REDIS_PASS) $$ADMIN_CONTAINER redis-cli -h redis --no-auth-warning DEL rabbitmq:cluster:members rabbitmq:cluster:master; \
		docker exec -e REDISCLI_AUTH=$(REDIS_PASS) $$ADMIN_CONTAINER sh -c 'redis-cli -h redis --no-auth-warning KEYS "rabbitmq:node:*:heartbeat" | xargs -r redis-cli -h redis --no-auth-warning DEL'; \
		echo "Cluster state cleared"; \
	else \
		echo "redis: container not found on host manager1"; \
	fi

# PostgreSQL
postgres:
	@PG_CONTAINER=$$(docker ps -qf "name=$(PROJECT_NAME)_postgres"); \
	if [ -n "$$PG_CONTAINER" ]; then \
		echo "PostgreSQL Info"; \
		docker exec $$PG_CONTAINER psql -U $(PG_USER) -d schedulerdb -c "SELECT version();" 2>/dev/null || echo "Failed to get PostgreSQL version"; \
		echo ""; \
		echo "Databases"; \
		docker exec $$PG_CONTAINER psql -U $(PG_USER) -d postgres -c "\l" 2>/dev/null || echo "Failed to list databases"; \
	else \
		echo "postgres: container not found on host manager1"; \
	fi

postgres-cli:
	@PG_CONTAINER=$$(docker ps -qf "name=$(PROJECT_NAME)_postgres"); \
	if [ -n "$$PG_CONTAINER" ]; then \
		echo "Connecting to PostgreSQL CLI..."; \
		docker exec -it $$PG_CONTAINER psql -U $(PG_USER) -d schedulerdb; \
	else \
		echo "postgres: container not found on host manager1"; \
	fi
postgres-drop-db:
	@PG_CONTAINER=$$(docker ps -qf "name=$(PROJECT_NAME)_postgres"); \
	if [ -n "$$PG_CONTAINER" ]; then \
		echo "Drop schedulerdb? [y/N]" && read ans && [ $${ans:-N} = y ] && \
		docker exec $$PG_CONTAINER psql -U $(PG_USER) -d postgres -c "DROP DATABASE IF EXISTS schedulerdb;" && \
		echo "schedulerdb dropped" || echo "Drop cancelled"; \
	else \
		echo "postgres: container not found on host manager1"; \
	fi

postgres-create-db:
	@PG_CONTAINER=$$(docker ps -qf "name=$(PROJECT_NAME)_postgres"); \
	if [ -n "$$PG_CONTAINER" ]; then \
		docker exec $$PG_CONTAINER psql -U $(PG_USER) -d postgres -c "CREATE DATABASE schedulerdb;" 2>/dev/null || echo "schedulerdb may already exist"; \
	else \
		echo "postgres: container not found on host manager1"; \
	fi

# Debug & Monitoring
debug:
	@echo "Stack Debug Info"
	@echo ""
	@echo "Stack Services:"
	@docker stack services $(PROJECT_NAME)
	@echo ""
	@echo "Stack Tasks:"
	@docker stack ps $(PROJECT_NAME) --no-trunc
	@echo ""
	@echo "Network:"
	@docker network ls | grep $(PROJECT_NAME) || echo "No networks found"
	@echo ""
	@echo "Volumes:"
	@docker volume ls | grep $(PROJECT_NAME) || echo "No volumes found"

monitor:
	@echo "Monitoring (CTRL+C to stop)..."
	@watch -n 2 'make health'

# Help
help:
	@echo "Fog Computing Scheduler - Essential Commands"
	@echo ""
	@echo "Quick Start:"
	@echo "  make all               Install deps + start services"
	@echo "  make up                Start all services"
	@echo "  make down              Stop all services"
	@echo "  make status            Show service status"
	@echo "  make health            Health check"
	@echo ""
	@echo "Development:"
	@echo "  make dev-scheduler     Run scheduler locally (hot reload)"
	@echo "  make dev-node NODE=1   Run fog node locally"
	@echo "  make build             Build binaries"
	@echo "  make test              Run tests"
	@echo "" 
	@echo "RabbitMQ:"
	@echo "  make rabbitmq          Show cluster/queues/users"
	@echo "  make rabbitmq-cli      Open postgreSQL CLI"
	@echo "  make rabbitmq-ui       Open management UI"
	@echo "  make rabbitmq-purge    Purge all queues"
	@echo ""
	@echo "Redis:"
	@echo "  make redis             Show info/keys/cluster state"
	@echo "  make redis-cli         Open Redis CLI"
	@echo "  make redis-flush       Delete all data"
	@echo "  make redis-clear-cluster    Clear cluster state"
	@echo ""
	@echo "PostgreSQL:"
	@echo "  make postgres          Show PG version and databases"
	@echo "  make postgres-cli      Open psql shell"
	@echo "  make postgres-create-db   Create schedulerdb"
	@echo "  make postgres-drop-db     Drop schedulerdb"
	@echo ""
	@echo "Logs & Debug:"
	@echo "  make logs              Recent logs"
	@echo "  make logs-follow       Follow all logs"
	@echo "  make debug             Stack debug info"
	@echo "  make monitor           Live health monitoring"
	@echo ""
	@echo "Maintenance:"
	@echo "  make restart           Restart services"
	@echo "  make clean             Remove all data"
	@echo "  make test-failover     Test node recovery"

