# Optimized RabbitMQ Scheduler

A highly available, distributed fog computing task scheduler built on Docker Swarm with RabbitMQ clustering, Redis-based coordination, and PostgreSQL for persistent task metadata storage.

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Infrastructure Components](#infrastructure-components)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Initialization Flow](#initialization-flow)
- [Failover Flow](#failover-flow)
- [Configuration](#configuration)
- [Operations & Monitoring](#operations--monitoring)
- [Support](#support)

---

## Overview

This project implements an intelligent task scheduler for fog computing environments with the following features:

- **High Availability**: 3-node RabbitMQ cluster with quorum queues
- **Distributed Coordination**: Redis-based cluster membership tracking and heartbeat management
- **Persistent Task Store**: PostgreSQL database for reliable task metadata storage
- **Priority Scheduling**: Multi-tier task prioritization system
- **Fault Tolerance**: Automatic failover and node recovery with Redis dependency checks
- **Resource Awareness**: CPU/memory-constrained worker tiers

### Key Technologies

- **RabbitMQ 4.1.6**: Message queue cluster with management plugin
- **Redis 7.2**: Coordination state and cluster membership (command-line configured)
- **PostgreSQL 18**: Task metadata and scheduler state persistence
- **Docker Swarm**: Orchestration platform
- **Prometheus + Grafana**: Metrics collection and visualization

### Project Status

**Infrastructure**: Production-ready (RabbitMQ cluster, Redis coordination, PostgreSQL persistence, monitoring stack)

**Application Layer**: Fully Implemented
- **Scheduler Brain**: Intelligent task distribution based on real-time node metrics and resource constraints.
- **Intelligent Fog Nodes**: Autonomous workers with heartbeat registration, metrics reporting, and task execution.

---

## Architecture

### System Topology

```
┌─────────────────────────────────────────────────────────────────┐
│                      Docker Swarm Cluster                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Manager Nodes (3)                    Worker Nodes (2)          │
│  ┌───────────────┐                    ┌─────────────────┐       │
│  │   manager1    │                    │    worker1      │       │
│  │ ┌───────────┐ │                    │  ┌───────────┐  │       │
│  │ │rabbitmq1  │ │                    │  │fog-node-1 │  │       │
│  │ │(master)   │◄├────┐               │  │(executor) │  │       │
│  │ └───────────┘ │    │               │  └───────────┘  │       │
│  │ ┌───────────┐ │    │               └─────────────────┘       │
│  │ │  redis    │ │    │               ┌─────────────────┐       │
│  │ │  (6379)   │ │    │               │    worker2      │       │
│  │ └───────────┘ │    │               │  ┌───────────┐  │       │
│  │ ┌───────────┐ │    │               │  │fog-node-2 │  │       │
│  │ │ postgres  │ │    │               │  │(executor) │  │       │
│  │ │  (5432)   │ │    │               │  └───────────┘  │       │
│  │ └───────────┘ │    │               └─────────────────┘       │
│  │ ┌───────────┐ │    │                                         │
│  │ │prometheus │ │    │  ◄─ Metrics Collection                  │
│  │ └───────────┘ │    │                                         │
│  │ ┌───────────┐ │    │                                         │
│  │ │ grafana   │ │    │  ◄─ Visualization                       │
│  │ └───────────┘ │    │                                         │
│  └───────────────┘    │                                         │
│                       │                                         │
│  ┌───────────────┐    │                                         │
│  │   manager2    │    │                                         │
│  │ ┌───────────┐ │    │                                         │
│  │ │rabbitmq2  │◄├────┤                                         │
│  │ │(replica)  │ │    │                                         │
│  │ └───────────┘ │    │                                         │
│  └───────────────┘    │                                         │
│                       │                                         │
│  ┌───────────────┐    │                                         │
│  │   manager3    │    │                                         │
│  │ ┌───────────┐ │    │                                         │
│  │ │rabbitmq3  │◄├────┘                                         │
│  │ │(replica)  │ │                                              │
│  │ └───────────┘ │                                              │
│  └───────────────┘                                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    fog-network (overlay)
```

### Component Distribution

| Node | Role | Services | Ports |
|------|------|----------|-------|
| **manager1** | Manager | rabbitmq1 (master), redis, postgres, prometheus, grafana | 15672, 6379, 5432, 9090, 3000 |
| **manager2** | Manager | rabbitmq2 (replica) | 15673 |
| **manager3** | Manager | rabbitmq3 (replica) | 15674 |
| **worker1** | Worker | fog-node-1 (executor) | - |
| **worker2** | Worker | fog-node-2 (executor) | - |

### Data Flow Architecture

```
┌──────────────────────────────────────────────┐
│   Scheduler (Under Development)              │
│   - Reads tasks from PostgreSQL              │
│   - Publishes to RabbitMQ                    │
│   - Coordinates via Redis                    │
└──────────────────────────────────────────────┘
            │             │              │
            ▼             ▼              ▼
        ┌────────────┐  ┌─────────┐  ┌──────────┐
        │ PostgreSQL │  │RabbitMQ │  │  Redis   │
        │(metadata)  │  │(queues) │  │(state)   │
        └────────────┘  └─────────┘  └──────────┘
                              │
                              ▼
                   ┌──────────────────┐
                   │   Fog Nodes      │
                   │ (NOT YET CODED)  │
                   │ - Consume tasks  │
                   │ - Execute work   │
                   │ - Publish results│
                   └──────────────────┘
```

---

## The Scheduler Brain (Intelligent Core)

The "Brain" of the system resides in the `internal/core/service/scheduler.go`, implementing a polling-based intelligent distribution logic.

### 1. Polling & Monitoring
The scheduler runs a continuous loop that:
- **Polls PostgreSQL**: Fetches tasks in `PENDING` status.
- **Consults Redis**: Retrieves the list of currently active worker nodes.
- **Fetches Metrics**: Queries Prometheus for real-time CPU and Memory usage of all active nodes.

### 2. Intelligent Selection Logic
When assigning a task, the scheduler evaluates all active nodes using a multi-criteria scoring algorithm:

**Constraints Check**:
- Does the node have enough `AvailableCPU` (Total - Used)?
- Does the node have enough `AvailableMemory`?

**Scoring Formula**:
Nodes that pass the constraints are scored to find the "best fit":
```go
Score = (FreeCPU / taskReqCPU * 0.6) + (FreeMemory / taskReqMemory * 0.4)
```
*The node with the highest score (most relative headroom) is selected for the task.*

### 3. Task State Machine
1.  **PENDING**: Task created in DB.
2.  **SCHEDULED**: Scheduler assigned a node and published to RabbitMQ.
3.  **RUNNING**: Worker consumed the task and started execution.
4.  **COMPLETED/FAILED**: Worker finished the task and updated the final status.

---

## Intelligent Fog Nodes (Workers)

Workers are autonomous agents (`internal/core/service/worker.go`) that manage task execution and node health.

### 1. Autonomous Registration
- **Heartbeat**: Every 10 seconds, workers register themselves in Redis with a TTL.
- **Capacity Reporting**: Workers report their total CPU and Memory capacity during registration.

### 2. Real-time Metrics
- **Prometheus Integration**: Each worker exposes a `/metrics` endpoint (port 2112).
- **Resource Tracking**: Workers report simulated real-time CPU and Memory usage, which the Scheduler uses for selection.

### 3. Distributed Consumption
- **RabbitMQ Priority**: Workers consume tasks from RabbitMQ quorum queues.
- **Graceful Execution**: Workers update the task status in PostgreSQL to `RUNNING` before execution and `COMPLETED` after success.

---

## Infrastructure Components

### 1. RabbitMQ Cluster (Message Bus)
- **High Availability**: 3-node cluster (manager1, manager2, manager3) using Quorum Queues.
- **Topology**: 5 exchanges and 7 priority-aware queues configured with dead-letter routing.
- **Health Checks**: Integrated with Docker Swarm for automatic failover.

### 2. Redis Coordination (State Store)
- **Role**: Mandatory for cluster initialization, heartbeat management, and master election.
- **Persistence**: AOF enabled to prevent state loss during restarts.
- **Scaling**: Configured with 1GB memory limit and LRU eviction.

### 3. PostgreSQL (Persistence)
- **Schema**: Stores task metadata, scheduling history, and configuration.
- **Durability**: WAL-based persistence with dedicated volume mapping.

### 4. Monitoring Stack
- **Prometheus**: Scrapes metrics from RabbitMQ nodes and Worker instances.
- **Grafana**: Visualizes cluster health, queue depths, and node resource utilization.

---

## Prerequisites

### Software Requirements
- Docker Engine 20.10+
- Docker Compose 1.29+ (with Compose v3.8 support)
- Docker Swarm initialized
- Go 1.21+ (for local development, optional)

### Hardware Requirements
- **Manager Nodes**: 2 CPU cores, 4GB RAM minimum (per node)
- **Worker Nodes**: 1 CPU core, 2GB RAM minimum (per node)
- **Disk Space**: 10GB available per node

### Environment Variables
Create a `.env` file with the following:
```bash
# Redis
REDIS_PASS=your_secure_redis_password

# RabbitMQ Cluster
RABBITMQ_ERLANG_COOKIE=your_secure_erlang_cookie

# RabbitMQ Admin
MQ_ADMIN_USER=admin
MQ_ADMIN_PASS=your_admin_password

# RabbitMQ Worker Credentials
MQ_NODE1_WORKER=worker1
MQ_NODE1_PASS=worker1_password
MQ_NODE2_WORKER=worker2
MQ_NODE2_PASS=worker2_password
MQ_NODE3_WORKER=worker3
MQ_NODE3_PASS=worker3_password

# PostgreSQL
PG_USER=scheduler
PG_PASS=your_postgres_password

# Grafana
GRAFANA_PASS=your_grafana_admin_password
```

---

## Quick Start

### 1. Initialize Swarm Cluster
```bash
# On manager1
docker swarm init --advertise-addr <manager1-ip>

# On manager2 and manager3
docker swarm join --token <manager-token> <manager1-ip>:2377

# On worker1 and worker2
docker swarm join --token <worker-token> <manager1-ip>:2377
```

### 2. Label Worker Nodes
Commands executed from the master manager:
```bash
# Label manager nodes
docker node update --label-add manager-master=true {manager1-hostname}
docker node update --label-add manager-rep1=true {manager2-hostname}
docker node update --label-add manager-rep2=true {manager3-hostname}

# Label worker nodes
docker node update --label-add worker1=true {worker1-hostname}
docker node update --label-add worker2=true {worker2-hostname}
```

### 3. Deploy Stack
Commands executed from the master manager:
```bash
# Clone repository
git clone https://github.com/Crabzie/Optimized-RabbitMQ-Scheduler.git
cd Optimized-RabbitMQ-Scheduler

# Update .env file (see Prerequisites)
nano .env

# Deploy stack (automated sequencing)
make up
```

The `make up` command handles sequential startup:
1. Deploy stack with all services
2. Wait for PostgreSQL to be healthy
3. Wait for Redis to be healthy  
4. Start RabbitMQ1 (master)
5. Start RabbitMQ2 and wait for cluster join
6. Start RabbitMQ3 and wait for cluster join

### 4. Verify Deployment
Commands executed from the master manager:
```bash
# Check services status
make status

# Check services health
make health

# Check RabbitMQ cluster status
make rabbitmq

# Check Redis connectivity
make redis

# Check PostgreSQL
make postgres

# View available commands
make help
```

### 5. Access Management Interfaces
- **RabbitMQ1**: http://manager1-ip:15672
- **RabbitMQ2**: http://manager2-ip:15673
- **RabbitMQ3**: http://manager3-ip:15674
- **Prometheus**: http://manager1-ip:9090
- **Grafana**: http://manager1-ip:3000
- **Username (RabbitMQ)**: `admin` (from `.env`)
- **Password (RabbitMQ)**: `MQ_ADMIN_PASS` (from `.env`)

---

## Initialization Flow

### Cold Start (First Deployment)

```
Step 1: PostgreSQL Initialization
══════════════════════════════════
┌──────────┐
│Postgres  │  Starts on manager1
│  Start   │  - Loads postgresql.conf
└────┬─────┘  - Binds to 0.0.0.0:5432
     │        - Initializes data directory
     │        - Creates schedulerdb database
     ▼
┌──────────┐
│Postgres  │  Health check passes
│  Ready   │  - pg_isready → accepting connections
└────┬─────┘
     │
Step 2: Redis Initialization
═════════════════════════════
     ▼
┌──────────┐
│  Redis   │  Starts on manager1
│  Start   │  - Command-line config applied
└────┬─────┘  - --appendonly yes
     │        - --maxmemory 1G
     │        - --maxmemory-policy allkeys-lru
     │        - --requirepass ${REDIS_PASS}
     ▼
┌──────────┐
│  Redis   │  Health check passes
│  Ready   │  - redis-cli ping → PONG
└────┬─────┘
     │
Step 3: RabbitMQ1 (Primary) Initialization
═══════════════════════════════════════════
     ▼
     ┌─ Waits for RabbitMQ internal startup
     ├─ MANDATORY: Checks Redis connectivity (120s timeout)
     ├─ Reads Redis for existing cluster members
     ├─ If none: Bootstraps as master
     ├─ Sets master node in Redis
     ├─ Loads definitions.json (users, exchanges, queues, bindings)
     ├─ Starts 30s heartbeat loop
     └─ Ready for secondary nodes to join
     │
Step 4: RabbitMQ2 & RabbitMQ3 (Secondary) Initialization
═════════════════════════════════════════════════════════
     ▼
     ├─ Each waits for RabbitMQ internal startup
     ├─ MANDATORY: Checks Redis connectivity (120s timeout)
     ├─ Waits for master election in Redis (180s max)
     ├─ Verifies master reachability
     ├─ Verifies master Mnesia readiness
     ├─ Joins cluster via master node
     ├─ Registers in Redis cluster members
     ├─ Starts 30s heartbeat loop
     └─ Ready for task ingestion

Key Dependencies:
  • Redis MUST be online before init_infra.sh starts
    (If Redis unavailable: init_infra.sh exits, node restart loop)
  • Master must be elected before secondaries can join
  • All heartbeats stored in Redis for failover tracking

Result: Fully operational 3-node cluster ready for scheduler
```

### Redis Dependency Check (CRITICAL)

From `init_infra.sh`:
```bash
# MANDATORY: Redis connectivity check
until nc -z $REDIS_HOST $REDIS_PORT > /dev/null 2>&1; do
  ((WAIT_COUNT++))
  if [ $WAIT_COUNT -ge 120 ]; then
    echo "ERROR: Redis not reachable after 120s"
    exit 1
  fi
  sleep 1
done

# WITHOUT Redis, cluster coordination impossible
# - No membership tracking
# - No master election
# - No heartbeat management
# - No failover detection
```

**Why This Matters for Scheduler**: Scheduler needs guaranteed cluster state visibility. Redis failure blocks cluster initialization entirely.

---

## Failover Flow

### Scenario 1: Single Node Failure (rabbitmq2 crashes)

```
Initial: 3/3 nodes healthy, heartbeats active
Event: rabbitmq2 crashes
     │
     ├─ T+90s: Heartbeat expires (TTL 90s in Redis)
     ├─ Redis auto-removes stale node from members
     ├─ Cluster recognized as 2/3 nodes
     ├─ Quorum maintained (majority rule)
     │
     ├─ T+120s: Docker restart policy triggers (on-failure)
     │
     ├─ T+125s: rabbitmq2 container restarts
     │   ├─ RabbitMQ internal startup
     │   ├─ CRITICAL: Checks Redis connectivity
     │   ├─ Reads cluster members from Redis
     │   ├─ Decision: REJOIN existing cluster
     │   ├─ Rejoins via any active member
     │   └─ Registers in Redis
     │
     └─ T+160s: Cluster restored 3/3 nodes
         Queue leaders rebalanced
         Quorum queue replicas synced

Impact: ~60s downtime per node (worst case)
Data Loss: NONE (quorum maintained during outage)
```

### Scenario 2: Redis Failure During Node Restart

```
Initial: All systems healthy
Event: RabbitMQ2 crashes + Redis goes down simultaneously
     │
     ├─ T+0s: Both services down
     │
     ├─ T+120s: RabbitMQ2 restart attempt
     │   └─ CRITICAL: Redis connectivity check FAILS
     │       ├─ Exits init_infra.sh
     │       └─ Node restart loop (until Redis available)
     │
     ├─ Cluster State: 2/3 nodes running (rabbitmq1, rabbitmq3)
     │   └─ Quorum maintained
     │   └─ Message delivery continues
     │
     ├─ RabbitMQ2 State: Restart loop
     │   └─ Retries every 10s (Docker restart policy)
     │   └─ Waits for Redis to come back
     │
     └─ When Redis recovers:
         ├─ Next RabbitMQ2 restart succeeds
         ├─ Cluster coordination resumes
         └─ Cluster restored 3/3 nodes

Cluster Resilience: Maintained (2/3 operational)
Message Delivery: Unaffected
Scheduler Impact: Cannot coordinate until Redis recovered
```

### Scenario 3: PostgreSQL Failure

```
Initial: All systems healthy
Event: PostgreSQL crashes
     │
     ├─ RabbitMQ Cluster: UNAFFECTED (independent operation)
     ├─ Message Flow: UNAFFECTED
     ├─ Scheduler: Cannot read/write task metadata
     │
     ├─ T+60s: Docker restart (typical)
     │   └─ PostgreSQL WAL recovery
     │
     └─ Cluster operational throughout

Impact: Scheduler blocked during outage
Data Loss: NONE (WAL recovery)
Message Queue: Continues buffering tasks
```

---

## Configuration

### RabbitMQ Configuration (rabbitmq.conf)

See `config/rabbitmq/rabbitmq.conf` - Includes network, memory, cluster, and queue settings

### PostgreSQL Configuration (postgresql.conf)

See `config/postgres/postgresql.conf` - Includes connection, logging, WAL, and memory settings

### RabbitMQ Definitions (definitions.json)

See `config/rabbitmq/definitions.json` - Defines vhosts, exchanges, queues, bindings, and users:
- **Vhost**: `/fog`
- **Exchanges**: Direct, fanout, and topic types for task routing
- **Queues**: Priority tiers (high/normal/low) with dead-letter routing
- **Users**: Admin and worker credentials

### Prometheus Configuration (prometheus.yml)

See `config/prometheus/prometheus.yml` - Scrapes metrics from all RabbitMQ nodes and Prometheus itself

### Redis Configuration

Configured entirely via command-line in `compose.yml`:
```yaml
command:
  - redis-server
  - "--appendonly" 
  - "yes"
  - "--maxmemory"
  - "1G"
  - "--maxmemory-policy"
  - "allkeys-lru"
  - "--requirepass"
  - "${REDIS_PASS}"
```

---

## Operations & Monitoring

### Essential Commands (via Makefile)

#### How To Start
```bash
make all               # Install deps + start services
make up                # Start all services (sequenced)
make down              # Stop all services
make restart           # Restart services
make clean             # Remove all data (confirm required)
```

#### Health Checks
```bash
make status            # Show service status
make health            # Check all services health
make rabbitmq          # Show RabbitMQ cluster/queues/users
make redis             # Show Redis info/keys/cluster state
make postgres          # Show PostgreSQL version and databases
```

#### Interactive CLI Access
```bash
make rabbitmq-cli      # Open RabbitMQ shell
make redis-cli         # Open Redis CLI
make postgres-cli      # Open PostgreSQL psql shell
```

#### Logs & Debugging
```bash
make logs              # Recent logs (RabbitMQ, Redis, PostgreSQL)
make logs-follow       # Follow all logs (live)
make debug             # Stack debug info
make monitor           # Live health monitoring (watch)
```

#### Management Operations
```bash
make rabbitmq-ui       # Open RabbitMQ Management UI
make rabbitmq-purge    # Purge all queues (confirm required)
make redis-flush       # Delete all Redis data (confirm required)
make postgres-create-db   # Create schedulerdb
```

#### Testing
```bash
make test              # Run tests (to be done)
make test-failover     # Test node recovery
```

### Health Check Output Example

```bash
$ make health

Service Health
rabbitmq1: healthy
rabbitmq2: healthy
rabbitmq3: healthy

redis: healthy

Redis Coordinator
Members: rabbit@rabbitmq1 rabbit@rabbitmq2 rabbit@rabbitmq3
Master:  rabbit@rabbitmq1

postgres: healthy
```

---

## Support

### System Support
The repo includes a Makefile with helpful commands. On the manager node:
```bash
cd Optimized-RabbitMQ-Scheduler
make help
```

### Issues
For issues and questions:
- GitHub Issues: https://github.com/Crabzie/Optimized-RabbitMQ-Scheduler/issues
- Email: hamzalagab.tech@gmail.com

---

## License

This project is licensed under the MIT License - see the LICENSE file for details.
