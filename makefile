# Makefile for Fog Computing Scheduler

include .env
export

# Project name (used by Docker Compose as prefix)
PROJECT_NAME=fog-scheduler
COMPOSE_PROJECT_NAME=$(PROJECT_NAME)

# Binary names
BINARY_SCHEDULER=scheduler
BINARY_NODE=fog-node

# Container names (Docker Compose uses project_name as prefix)
RABBITMQ1_CONTAINER=$(shell docker ps --filter "name=fog-scheduler_rabbitmq1" --format "{{.Names}}" | head -1)
RABBITMQ2_CONTAINER=$(shell docker ps --filter "name=fog-scheduler_rabbitmq2" --format "{{.Names}}" | head -1)
RABBITMQ3_CONTAINER=$(shell docker ps --filter "name=fog-scheduler_rabbitmq3" --format "{{.Names}}" | head -1)
REDIS_CONTAINER=$(shell docker ps --filter "name=fog-scheduler_redis" --format "{{.Names}}" | head -1)

# Default node for commands
NODE?=1
NODE_ID?=node-$(NODE)

.PHONY: all default install deps-go \
	service-up service-up-infra service-down service-restart service-clean service-status service-health service-rebuild \
	redis-cli redis-flush redis-health redis-keys \
	rabbitmq-health rabbitmq-cluster rabbitmq-queues rabbitmq-queues-purge rabbitmq-users rabbitmq-vhosts rabbitmq-permissions rabbitmq-ui \
	dev-scheduler dev-node dev-all \
	build-scheduler build-node build-all \
	run-scheduler run-node \
	logs-rabbitmq logs-redis logs-infra logs-rabbitmq-follow logs-rabbitmq-nodes logs-scheduler logs-nodes\
	test test-integration test-unit \
	clean clean-all \
	fmt lint check \
	docs-deps docs-generate \
	monitor inspect-node inspect-scheduler inspect-rabbitmq inspect-redis debug debug-infra help info

default: install service-up
	@echo "Setup complete! Run 'make dev-scheduler' or 'make dev-node NODE=1' to start development"

install:
	@echo "Installing Go dependencies..."
	$(MAKE) deps-go
	go install github.com/air-verse/air@latest
	@echo "Dependencies installed"

deps-go:
	go get github.com/rabbitmq/amqp091-go
	go get github.com/redis/go-redis/v9
	go mod tidy

# ==========================================
# Docker Services
# ==========================================

service-up:
	@echo "Starting infrastructure sequentially..."
	@echo ""
	@echo "Step 1: Deploying stack and starting Redis..."
	docker stack deploy -c compose.yml fog-scheduler
	docker service scale fog-scheduler_rabbitmq1=0 fog-scheduler_rabbitmq2=0 fog-scheduler_rabbitmq3=0
	@sleep 10
	@echo ""
	@echo "Step 2: Starting RabbitMQ1 (master node)..."
	docker service scale fog-scheduler_rabbitmq1=1
	@echo "Waiting for RabbitMQ1 to initialize (60s)..."
	@sleep 60
	@echo "Verifying RabbitMQ1 cluster readiness..."
	@bash -c 'for i in {1..24}; do \
	CONTAINER=$$(docker ps --filter name=fog-scheduler_rabbitmq1 --format "{{.Names}}" | head -1); \
		if [ -n "$$CONTAINER" ] && docker exec $$CONTAINER rabbitmq-diagnostics ping >/dev/null 2>&1; then \
			echo "rabbitmq1 ready"; \
			exit 0; \
		fi; \
		echo "waiting for rabbitmq1 (attempt $$i)..."; \
		if [ $$(( $$i % 6 )) -eq 0 ]; then \
			echo "Container status:"; \
			docker ps --filter name=fog-scheduler_rabbitmq1; \
			echo "Container logs:"; \
			docker logs $$CONTAINER --tail 10; \
		fi; \
		sleep 5; \
	done; \
	echo "rabbitmq1 failed to start"; \
	exit 1'
	@echo ""
	@echo "Step 3: Starting RabbitMQ2 (secondary node)..."
	docker service scale fog-scheduler_rabbitmq2=1
	@echo "Waiting for RabbitMQ2 to start (60s)..."
	@sleep 60
	@echo "Verifying RabbitMQ2 joined cluster..."
	@bash -c 'for i in {1..24}; do \
		CONTAINER=$$(docker ps --filter name=fog-scheduler_rabbitmq1 --format "{{.Names}}" | head -1); \
		if [ -n "$$CONTAINER" ] && docker exec $$CONTAINER rabbitmqctl cluster_status 2>/dev/null | grep -q rabbit@rabbitmq2; then \
			echo "rabbitmq2 joined cluster"; \
			exit 0; \
		fi; \
		printf "."; \
		sleep 5; \
	done; \
	echo "rabbitmq2 failed to join"; \
	exit 1'
	@echo ""
	@echo "Step 4: Starting RabbitMQ3 (secondary node)..."
	docker service scale fog-scheduler_rabbitmq3=1
	@echo "Waiting for RabbitMQ3 to start (60s)..."
	@sleep 60
	@echo "Verifying RabbitMQ3 joined cluster..."
	@bash -c 'for i in {1..24}; do \
		CONTAINER=$$(docker ps --filter name=fog-scheduler_rabbitmq1 --format "{{.Names}}" | head -1); \
		if [ -n "$$CONTAINER" ] && docker exec $$CONTAINER rabbitmqctl cluster_status 2>/dev/null | grep -q rabbit@rabbitmq3; then \
			echo "rabbitmq3 joined cluster"; \
			exit 0; \
		fi; \
		printf "."; \
		sleep 5; \
	done; \
	echo "rabbitmq3 failed to join"; \
	exit 1'
	@echo ""
	@echo "All services started successfully!"
	@echo ""
	$(MAKE) service-status

service-up-infra:
	@echo "Starting infrastructure only..."
	docker stack deploy -c compose.yml fog-scheduler
	$(MAKE) service-wait
	$(MAKE) service-status

service-down:
	@echo "Stopping services..."
	docker stack rm fog-scheduler
	@echo "Waiting for cleanup..."
	@sleep 10

service-restart:
	$(MAKE) service-down
	$(MAKE) service-up

service-clean:
	@echo "Cleaning up..."
	docker stack rm fog-scheduler
	@sleep 10
	docker volume prune -f
	@echo "All volumes removed"

service-status:
	@docker stack ps fog-scheduler
	@echo ""
	@docker service ls --filter "label=com.docker.stack.namespace=fog-scheduler"
	@echo ""
	@echo "RabbitMQ Management UI:"
	@echo "   → http://localhost:15672  (rabbitmq1)"
	@echo "   → http://localhost:15673  (rabbitmq2)"
	@echo "   → http://localhost:15674  (rabbitmq3)"
	@echo "   Username: $(MQ_ADMIN_USER)"
	@echo "   Password: $(MQ_ADMIN_PASS)"
	@echo ""
	@echo "Redis:"
	@echo "   → localhost:6379"
	@echo "   Password: $(REDIS_PASS)"

service-health:
	@echo "Cluster Health Check:"
	@echo "---------------------"
	@if [ -n "$(RABBITMQ1_CONTAINER)" ]; then \
		echo -n "RabbitMQ1: "; \
		docker exec $(RABBITMQ1_CONTAINER) rabbitmq-diagnostics ping 2>/dev/null && echo "✓ OK" || echo "✗ DOWN"; \
	else \
		echo "RabbitMQ1: ✗ NOT RUNNING"; \
	fi
	@if [ -n "$(RABBITMQ2_CONTAINER)" ]; then \
		echo -n "RabbitMQ2: "; \
		docker exec $(RABBITMQ2_CONTAINER) rabbitmq-diagnostics ping 2>/dev/null && echo "✓ OK" || echo "✗ DOWN"; \
	else \
		echo "RabbitMQ2: ✗ NOT RUNNING"; \
	fi
	@if [ -n "$(RABBITMQ3_CONTAINER)" ]; then \
		echo -n "RabbitMQ3: "; \
		docker exec $(RABBITMQ3_CONTAINER) rabbitmq-diagnostics ping 2>/dev/null && echo "✓ OK" || echo "✗ DOWN"; \
	else \
		echo "RabbitMQ3: ✗ NOT RUNNING"; \
	fi
	@if [ -n "$(REDIS_CONTAINER)" ]; then \
		echo -n "Redis: "; \
		docker exec $(REDIS_CONTAINER) redis-cli -a $(REDIS_PASS) ping 2>/dev/null | grep -q PONG && echo "✓ OK" || echo "✗ DOWN"; \
	else \
		echo "Redis: ✗ NOT RUNNING"; \
	fi

service-rebuild:
	@echo "Rebuilding services..."
	docker compose build --no-cache
	$(MAKE) service-down
	$(MAKE) service-up

# ==========================================
# Redis Commands
# ==========================================

redis-cli:
	docker exec -it $(REDIS_CONTAINER) redis-cli -a $(REDIS_PASS)

redis-flush:
	@echo "This will delete ALL Redis data. Continue? [y/N]" && read ans && [ $${ans:-N} = y ]
	docker exec $(REDIS_CONTAINER) redis-cli -a $(REDIS_PASS) FLUSHALL
	@echo "Redis flushed"

redis-health:
	@echo "Redis Status:"
	@[ -n "$(REDIS_CONTAINER)" ] && docker exec $(REDIS_CONTAINER) redis-cli -a $(REDIS_PASS) INFO server | grep redis_version || echo "Container not running"

redis-keys:
	docker exec $(REDIS_CONTAINER) redis-cli -a $(REDIS_PASS) KEYS '*'

# ==========================================
# RabbitMQ Commands
# ==========================================

rabbitmq-health:
	@echo "=== RabbitMQ1 Status ==="
	@[ -n "$(RABBITMQ1_CONTAINER)" ] && docker exec $(RABBITMQ1_CONTAINER) rabbitmqctl status || echo "Container not running"
	@echo ""
	@echo "=== RabbitMQ2 Status ==="
	@[ -n "$(RABBITMQ2_CONTAINER)" ] && docker exec $(RABBITMQ2_CONTAINER) rabbitmqctl status || echo "Container not running"
	@echo ""
	@echo "=== RabbitMQ3 Status ==="
	@[ -n "$(RABBITMQ3_CONTAINER)" ] && docker exec $(RABBITMQ3_CONTAINER) rabbitmqctl status || echo "Container not running"

rabbitmq-cluster:
	@echo "RabbitMQ Cluster Status:"
	@if [ -n "$(RABBITMQ1_CONTAINER)" ]; then \
		docker exec $(RABBITMQ1_CONTAINER) rabbitmqctl cluster_status; \
	else \
		echo "Error: rabbitmq1 container not found"; \
	fi

rabbitmq-queues:
	@echo "RabbitMQ Queues:"
	@docker exec $(RABBITMQ1_CONTAINER) rabbitmqctl list_queues name messages consumers type

rabbitmq-queues-purge:
	@echo "Purging all task queues..."
	docker exec $(RABBITMQ1_CONTAINER) rabbitmqctl purge_queue tasks.high_priority --vhost /fog
	docker exec $(RABBITMQ1_CONTAINER) rabbitmqctl purge_queue tasks.normal --vhost /fog
	docker exec $(RABBITMQ1_CONTAINER) rabbitmqctl purge_queue tasks.low_priority --vhost /fog
	@echo "Queues purged"

rabbitmq-users:
	@echo "RabbitMQ Users:"
	@docker exec $(RABBITMQ1_CONTAINER) rabbitmqctl list_users

rabbitmq-vhosts:
	@echo "RabbitMQ Vhosts:"
	@docker exec $(RABBITMQ1_CONTAINER) rabbitmqctl list_vhosts

rabbitmq-permissions:
	@echo "RabbitMQ Permissions (/fog):"
	@docker exec $(RABBITMQ1_CONTAINER) rabbitmqctl list_permissions -p /fog

rabbitmq-ui:
	@echo "Opening RabbitMQ Management UI..."
	@echo "URL: http://localhost:15672"
	@echo "Username: $(MQ_ADMIN_USER)"
	@echo "Password: $(MQ_ADMIN_PASS)"
	@which xdg-open > /dev/null && xdg-open http://localhost:15672 || \
	which open > /dev/null && open http://localhost:15672 || \
	which start > /dev/null && start http://localhost:15672 || \
	echo "Open http://localhost:15672 in your browser"

# ==========================================
# Development (Local)
# ==========================================

dev-scheduler: service-up-infra
	@echo "Starting scheduler with hot reload..."
	@cd cmd/scheduler && air

dev-node: service-up-infra
	@echo "Starting fog-node-$(NODE) locally..."
	@NODE_ID=$(NODE_ID) go run ./cmd/node/main.go

dev-all:
	$(MAKE) service-up

# ==========================================
# Build
# ==========================================

build-scheduler:
	@echo "Building scheduler..."
	@mkdir -p ./bin
	@go build -o ./bin/$(BINARY_SCHEDULER) ./cmd/scheduler/main.go
	@echo "Binary created → ./bin/$(BINARY_SCHEDULER)"

build-node:
	@echo "🔨 Building fog-node..."
	@mkdir -p ./bin
	@go build -o ./bin/$(BINARY_NODE) ./cmd/node/main.go
	@echo "Binary created → ./bin/$(BINARY_NODE)"

build-all: build-scheduler build-node
	@echo "All binaries built in ./bin/"

# ==========================================
# Run Binaries
# ==========================================

run-scheduler: service-up-infra build-scheduler
	@echo "Running scheduler..."
	@./bin/$(BINARY_SCHEDULER)

run-node: service-up-infra build-node
	@echo "Running fog-node-$(NODE)..."
	@NODE_ID=$(NODE_ID) ./bin/$(BINARY_NODE)

# ==========================================
# Logs
# ==========================================

# Logs for all RabbitMQ nodes (static)
logs-rabbitmq:
	@docker service logs fog-scheduler_rabbitmq1 --tail 100
	@docker service logs fog-scheduler_rabbitmq2 --tail 100
	@docker service logs fog-scheduler_rabbitmq3 --tail 100

# Logs for Redis
logs-redis:
	@docker service logs fog-scheduler_redis --tail 100

# Logs for all infra (RabbitMQ and Redis)
logs-infra:
	@docker service logs fog-scheduler_rabbitmq1 --tail 50
	@docker service logs fog-scheduler_rabbitmq2 --tail 50
	@docker service logs fog-scheduler_rabbitmq3 --tail 50
	@docker service logs fog-scheduler_redis --tail 50

# Logs for all RabbitMQ nodes (follow mode, CTRL+C to stop)
logs-rabbitmq-follow:
	@docker service logs -f fog-scheduler_rabbitmq1 &
	@docker service logs -f fog-scheduler_rabbitmq2 &
	@docker service logs -f fog-scheduler_rabbitmq3 &
	@wait

# Logs for single RabbitMQ node (by number)
logs-rabbitmq-node:
	@if [ -z "$(NODE)" ]; then \
		echo "Usage: make logs-rabbitmq-node NODE=1"; \
	else \
		docker service logs fog-scheduler_rabbitmq$(NODE) --tail 100; \
	fi

# Scheduler and node logs via Compose
logs-scheduler:
	docker compose logs -f scheduler

logs-nodes:
	docker compose logs -f fog-node-1 fog-node-2 fog-node-3

logs-node:
	docker compose logs -f fog-node-$(NODE)

# ==========================================
# Testing
# ==========================================

test:
	@echo "Running all tests..."
	@go test -v ./... -race -cover -timeout 30s -count 1 -coverprofile=coverage.out
	@go tool cover -html=coverage.out -o coverage.html
	@echo "Coverage Report → coverage.html"

test-integration: service-up-infra
	@echo "Running integration tests..."
	@go test -v ./tests/integration/... -tags=integration

test-unit:
	@echo "Running unit tests..."
	@go test -v ./internal/... -short

# ==========================================
# Cleanup
# ==========================================

clean:
	@echo "Cleaning build artifacts..."
	@rm -rf ./bin coverage.out coverage.html
	@echo "Build artifacts cleaned"

clean-all: clean service-clean
	@echo "Full cleanup complete"

# ==========================================
# Code Quality
# ==========================================

fmt:
	@echo "🎨 Formatting code..."
	@go fmt ./...
	@echo "Code formatted"

lint:
	@echo "🔍 Running linter..."
	@go vet ./...
	@echo "Lint passed"

check:
	@echo "🔍 Running all checks..."
	$(MAKE) fmt
	$(MAKE) lint
	$(MAKE) test
	@echo "All checks passed"

# ==========================================
# Documentation
# ==========================================

docs-deps:
	@echo "Installing documentation tools..."
	@go install github.com/swaggo/swag/cmd/swag@latest
	@echo "Documentation tools installed"

docs-generate: docs-deps
	@echo "Generating documentation..."
	@swag fmt
	@swag init -g ./cmd/scheduler/main.go -o ./docs --parseInternal true
	@echo "Documentation generated → ./docs"

# ==========================================
# Monitoring & Debugging
# ==========================================

monitor:
	@docker stats $(RABBITMQ1_CONTAINER) $(RABBITMQ2_CONTAINER) $(RABBITMQ3_CONTAINER) \
		$(REDIS_CONTAINER) $(SCHEDULER_CONTAINER) \
		$(PROJECT_NAME)-fog-node-1-1 $(PROJECT_NAME)-fog-node-2-1 $(PROJECT_NAME)-fog-node-3-1

inspect-node:
	@docker exec -it $(PROJECT_NAME)-fog-node-$(NODE)-1 /bin/sh

inspect-scheduler:
	@docker exec -it $(SCHEDULER_CONTAINER) /bin/sh

inspect-rabbitmq:
	@CONTAINER=$$(docker ps --filter "name=fog-scheduler_rabbitmq1" --format "{{.Names}}" | head -1); \
	if [ -z "$$CONTAINER" ]; then \
		echo "No rabbitmq1 container found"; \
		docker service ps fog-scheduler_rabbitmq1; \
	else \
		docker exec -it $$CONTAINER /bin/bash; \
	fi

inspect-redis:
	@CONTAINER=$$(docker ps --filter "name=fog-scheduler_redis" --format "{{.Names}}" | head -1); \
	if [ -z "$$CONTAINER" ]; then \
		echo "❌ No redis container found"; \
		docker service ps fog-scheduler_redis; \
	else \
		docker exec -it $$CONTAINER /bin/sh; \
	fi

debug:
	@echo "Debugging Stack Deployment"
	@echo ""
	@echo "=== Services ==="
	@docker service ls --filter "label=com.docker.stack.namespace=fog-scheduler"
	@echo ""
	@echo "=== Task Status ==="
	@docker stack ps fog-scheduler --no-trunc
	@echo ""
	@echo "=== Containers ==="
	@docker ps -a --filter "label=com.docker.stack.namespace=fog-scheduler"
	@echo ""
	@echo "=== Networks ==="
	@docker network ls | grep fog-scheduler
	@echo ""
	@echo "=== Volumes ==="
	@docker volume ls | grep fog-scheduler || echo "No volumes found"

debug-infra:
	@echo "Detailed Service Debug Info"
	@echo ""
	@echo "=== RabbitMQ1 ===" 
	@docker service ps fog-scheduler_rabbitmq1 --no-trunc
	@echo ""
	@echo "=== RabbitMQ2 ==="
	@docker service ps fog-scheduler_rabbitmq2 --no-trunc
	@echo ""
	@echo "=== RabbitMQ3 ==="
	@docker service ps fog-scheduler_rabbitmq3 --no-trunc
	@echo ""
	@echo "=== Redis ==="
	@docker service ps fog-scheduler_redis --no-trunc
	@echo ""
	@echo "Check logs with: make logs-rabbitmq"

# ==========================================
# Helper Commands
# ==========================================

help:
	@echo "Available Commands:"
	@echo ""
	@echo "Setup & Installation:"
	@echo "  make install            Install dependencies"
	@echo "  make deps-go            Install Go dependencies"
	@echo ""
	@echo "Service Management:"
	@echo "  make service-up         Start all services"
	@echo "  make service-up-infra   Start only infra (RabbitMQ + Redis)"
	@echo "  make service-down       Stop all services"
	@echo "  make service-restart    Restart services"
	@echo "  make service-clean      Remove containers and volumes"
	@echo "  make service-status     Show service status"
	@echo ""
	@echo "Development:"
	@echo "  make dev-scheduler      Run scheduler with hot reload"
	@echo "  make dev-node NODE=1    Run specific fog node locally"
	@echo "  make dev-all            Start all services in Docker"
	@echo ""
	@echo "Build:"
	@echo "  make build-all          Build all binaries"
	@echo "  make build-scheduler    Build scheduler binary"
	@echo "  make build-node         Build fog-node binary"
	@echo ""
	@echo "RabbitMQ:"
	@echo "  make rabbitmq-cluster   Show cluster status"
	@echo "  make rabbitmq-queues    List queues"
	@echo "  make rabbitmq-users     List users"
	@echo "  make rabbitmq-ui        Open management UI"
	@echo ""
	@echo "Redis:"
	@echo "  make redis-cli          Open Redis CLI"
	@echo "  make redis-keys         Show all keys"
	@echo "  make redis-flush        Delete all data"
	@echo ""
	@echo "Logs:"
	@echo "  make logs               View all logs"
	@echo "  make logs-rabbitmq      View RabbitMQ logs"
	@echo "  make logs-node NODE=1   View specific node logs"
	@echo ""
	@echo "Testing:"
	@echo "  make test               Run all tests with coverage"
	@echo "  make test-unit          Run unit tests"
	@echo "  make test-integration   Run integration tests"
	@echo ""
	@echo "Monitoring:"
	@echo "  make monitor            Show container stats"
	@echo "  make inspect-node NODE=1     Shell into fog node"
	@echo "  make inspect-scheduler       Shell into scheduler"

info:
	@echo "Fog Computing Scheduler Project"
	@echo ""
	@echo "Project Structure:"
	@tree -L 2 -I 'bin|vendor|.git|node_modules' . 2>/dev/null || \
		find . -maxdepth 2 -type d -not -path '*/\.*' -not -path '*/bin*' -not -path '*/vendor*' | sort
	@echo ""
	@echo "Environment:"
	@echo "   RabbitMQ Admin   → $(MQ_ADMIN_USER)"
	@echo "   RabbitMQ Worker1 → $(MQ_NODE1_WORKER)"
	@echo "   Redis Password   → $(REDIS_PASS)"
	@echo ""
	@echo "Quick Start:"
	@echo "   make service-up          → Start all services"
	@echo "   make dev-scheduler       → Run scheduler locally"
	@echo "   make dev-node NODE=1     → Run fog-node-1 locally"
	@echo "   make logs                → View all logs"
	@echo "   make rabbitmq-cluster    → Check cluster status"
	@echo "   make help                → Show all commands"
