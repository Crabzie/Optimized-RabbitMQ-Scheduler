# Makefile for Fog Computing Scheduler

include .env
export

# Project name
PROJECT_NAME=fog-scheduler
COMPOSE_PROJECT_NAME=$(PROJECT_NAME)

# Binary names
BINARY_SCHEDULER=scheduler
BINARY_NODE=fog-node

# admin container running on the manager
ADMIN_CONTAINER = $(shell docker ps -qf "name=$(PROJECT_NAME)_rabbitmq-admin")


# Default node
NODE?=1
NODE_ID?=node-$(NODE)

.PHONY: all install deps \
	up down restart clean status health \
	dev-scheduler dev-node \
	build test \
	logs logs-follow \
	rabbitmq redis \
	debug monitor \
	help

# ==========================================
# Quick Start
# ==========================================

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

# ==========================================
# Service Management
# ==========================================

up:
	@echo "Starting services sequentially..."
	@echo ""
	@echo "Step 1: Deploying stack..."
	@docker stack deploy -c compose.yml $(PROJECT_NAME)
	@docker service scale $(PROJECT_NAME)_rabbitmq1=0 $(PROJECT_NAME)_rabbitmq2=0 $(PROJECT_NAME)_rabbitmq3=0
	@sleep 10
	@echo ""
	@echo "Step 2: Starting RabbitMQ1 (master)..."
	@docker service scale $(PROJECT_NAME)_rabbitmq1=1
	@sleep 60
	@bash -c 'for i in {1..24}; do \
	  if docker exec $$(docker ps -qf "name=admin") rabbitmq-diagnostics -n rabbit@rabbitmq1 ping >/dev/null 2>&1; then \
	    echo "RabbitMQ1 ready"; \
	    exit 0; \
	  else \
	    printf "."; \
	    sleep 10; \
	  fi; \
	done; \
	echo "RabbitMQ1 failed to start"; \
	exit 1'
	@echo ""
	@echo "Step 3: Starting RabbitMQ2..."
	@docker service scale $(PROJECT_NAME)_rabbitmq2=1
	@sleep 60
	@bash -c 'for i in {1..24}; do \
	  if docker exec $$(docker ps -qf "name=admin") rabbitmqctl -n rabbit@rabbitmq1 cluster_status 2>/dev/null | grep -q "rabbit@rabbitmq2"; then \
	    echo "RabbitMQ2 joined cluster"; \
	    exit 0; \
	  else \
	    printf "."; \
	    sleep 10; \
	  fi; \
	done; \
	echo "RabbitMQ2 failed to join cluster"; \
	exit 1'
	@echo ""
	@echo "Step 4: Starting RabbitMQ3..."
	@docker service scale $(PROJECT_NAME)_rabbitmq3=1
	@sleep 60
	@bash -c 'for i in {1..24}; do \
	  if docker exec $$(docker ps -qf "name=admin") rabbitmqctl -n rabbit@rabbitmq1 cluster_status 2>/dev/null | grep -q "rabbit@rabbitmq3"; then \
	    echo "RabbitMQ3 joined cluster"; \
	    exit 0; \
	  else \
	    printf "."; \
	    sleep 10; \
	  fi; \
	done; \
	echo "RabbitMQ3 failed to join cluster"; \
	exit 1'
	@echo ""
	@echo "All services started!"
	@$(MAKE) status

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
		if  docker exec $$(docker ps -qf "name=admin") rabbitmq-diagnostics -n rabbit@$$svc ping >/dev/null 2>&1; then \
			echo "$$svc: healthy"; \
		else \
			echo "$$svc: not healthy"; \
		fi; \
	done
	@echo ""
	
	if docker exec $$(docker ps -qf "name=admin") redis-cli -h redis -a ${REDIS_PASS} --no-auth-warning ping >/dev/null 2>&1; then \
		echo "redis: healthy"; \
	else \
		echo "redis: not healthy"; \
	fi; \

	@echo ""
	@echo "Redis Coordinator"
	
	echo -n "Members: "; \
	docker exec $$(docker ps -qf "name=admin") redis-cli -h redis -a $(REDIS_PASS) --no-auth-warning SMEMBERS rabbitmq:cluster:members 2>/dev/null | tr '\n' ' '; \
	echo ""; \
	echo -n "Master:  "; \
	docker exec $$(docker ps -qf "name=admin") redis-cli -h redis -a $(REDIS_PASS) --no-auth-warning GET rabbitmq:cluster:master 2>/dev/null; \
	echo "";

# ==========================================
# Development
# ==========================================

dev-scheduler:
	@echo "Starting scheduler with hot reload..."
	@cd cmd/scheduler && air

dev-node:
	@echo "Starting fog-node-$(NODE)..."
	@NODE_ID=$(NODE_ID) go run ./cmd/node/main.go

# ==========================================
# Build
# ==========================================

build:
	@echo "Building binaries..."
	@mkdir -p ./bin
	@go build -o ./bin/$(BINARY_SCHEDULER) ./cmd/scheduler/main.go
	@go build -o ./bin/$(BINARY_NODE) ./cmd/node/main.go
	@echo "Binaries in ./bin/"

# ==========================================
# Testing
# ==========================================

test:
	@echo "Running tests..."
	@go test -v ./... -race -cover -timeout 30s -count 1

test-failover:
	@echo "Testing failover recovery..."
	@echo "Force restarting rabbitmq1..."
	@docker service update --force $(PROJECT_NAME)_rabbitmq1
	@sleep 90
	@$(MAKE) rabbitmq

# ==========================================
# Logs
# ==========================================

logs:
	@echo "Recent Logs"
	@docker service logs $(PROJECT_NAME)_rabbitmq1 --tail 50
	@docker service logs $(PROJECT_NAME)_redis --tail 30

logs-follow:
	@docker service logs -f $(PROJECT_NAME)_rabbitmq1 $(PROJECT_NAME)_rabbitmq2 $(PROJECT_NAME)_rabbitmq3 $(PROJECT_NAME)_redis

# ==========================================
# RabbitMQ
# ==========================================

rabbitmq:
	@echo "Cluster Status"
	docker exec $$(docker ps -qf "name=admin") rabbitmqctl -n rabbit@rabbitmq1 cluster_status 2>/dev/null;
	@echo ""
	@echo "Queues"
	docker exec $$(docker ps -qf "name=admin") rabbitmqctl -n rabbit@rabbitmq1 list_queues name messages consumers 2>/dev/null;
	@echo ""
	@echo "Users"
	docker exec $$(docker ps -qf "name=admin") rabbitmqctl -n rabbit@rabbitmq1 list_users 2>/dev/null;

rabbitmq-ui:
	@echo "Opening RabbitMQ Management UI..."
	@echo "URL: http://localhost:15672"
	@echo "User: $(MQ_ADMIN_USER)"
	@which xdg-open >/dev/null 2>&1 && xdg-open http://localhost:15672 || \
	which open >/dev/null 2>&1 && open http://localhost:15672 || \
	echo "Open http://localhost:15672 in your browser"

rabbitmq-purge:
	@echo "Purge all queues? [y/N]" && read ans && [ $${ans:-N} = y ]
	@for q in tasks.high_priority tasks.normal tasks.low_priority; do \
		docker exec $$(docker ps -qf "name=admin") rabbitmqctl -n rabbit@rabbitmq1 purge_queue $$q --vhost /fog; \
	done
	@echo "Queues purged"

# ==========================================
# Redis
# ==========================================

redis:
	@echo "=== Redis Info ==="
	docker exec $$(docker ps -qf "name=admin") redis-cli -h redis -a $(REDIS_PASS) --no-auth-warning INFO server | grep redis_version; \
	@echo ""
	@echo "Cluster State"
	docker exec $$(docker ps -qf "name=admin") redis-cli -h redis -a $(REDIS_PASS) --no-auth-warning SMEMBERS rabbitmq:cluster:members; \
	@echo ""
	@echo "All Keys"
	docker exec $$(docker ps -qf "name=admin") redis-cli -h redis -a $(REDIS_PASS) --no-auth-warning KEYS '*';

redis-cli:
	docker exec $$(docker ps -qf "name=admin") redis-cli -h redis -a $(REDIS_PASS);

redis-flush:
	@echo "Delete ALL Redis data? [y/N]" && read ans && [ $${ans:-N} = y ]
	docker exec $$(docker ps -qf "name=admin") redis-cli -h redis -a $(REDIS_PASS) --no-auth-warning FLUSHALL; \
	echo "Redis flushed";

redis-clear-cluster:
	@echo "Clear cluster state? [y/N]" && read ans && [ $${ans:-N} = y ]
	@docker exec $$(docker ps -qf "name=admin") redis-cli -h redis -a $(REDIS_PASS) --no-auth-warning DEL rabbitmq:cluster:members rabbitmq:cluster:master
	@docker exec $$(docker ps -qf "name=admin") redis-cli -h redis -a $(REDIS_PASS) --no-auth-warning KEYS "rabbitmq:node:*:heartbeat" | xargs -I {} docker exec $(docker ps -qf "name=admin") redis-cli -h redis -a $(REDIS_PASS) --no-auth-warning DEL {}
	@echo "Cluster state cleared"

# ==========================================
# Debug & Monitoring
# ==========================================

monitor:
	@echo "Monitoring (CTRL+C to stop)..."
	@watch -n 2 '$(MAKE) health'

# ==========================================
# Help
# ==========================================

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
	@echo "  make rabbitmq-ui       Open management UI"
	@echo "  make rabbitmq-purge    Purge all queues"
	@echo ""
	@echo "Redis:"
	@echo "  make redis             Show info/keys/cluster state"
	@echo "  make redis-cli         Open Redis CLI"
	@echo "  make redis-flush       Delete all data"
	@echo "  make redis-clear-cluster    Clear cluster state"
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
