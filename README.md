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
- **Redis 7.2**: Coordination state and cluster membership (configured via command-line)
- **PostgreSQL 18**: Task metadata and scheduler state persistence
- **Docker Swarm**: Orchestration platform
- **Alpine Linux**: Lightweight container base

### Project Status

**Infrastructure**: ✅ Production-ready (RabbitMQ cluster, Redis coordination, PostgreSQL persistence)

**Application Layer**: 🚧 Under development
- **Scheduler**: Core scheduling logic and task distribution (in progress)
- **Fog Nodes**: Task execution workers and result handlers (in progress)

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
| **manager1** | Manager | rabbitmq1 (master), redis, postgres | 15672, 6379, 5432 |
| **manager2** | Manager | rabbitmq2 (replica) | 15673 |
| **manager3** | Manager | rabbitmq3 (replica) | 15674 |
| **worker1** | Worker | fog-node-1 (executor) | - |
| **worker2** | Worker | fog-node-2 (executor) | - |

### Network Architecture

- **Network Type**: Overlay (attachable)
- **Name**: `fog-network`
- **Driver**: overlay
- **Scope**: Swarm-wide
- **DNS**: Automatic service discovery

### Data Flow Architecture

```
┌──────────────┐
│   Scheduler  │  (Under Development)
│   (manager1) │
└──────┬───────┘
       │
       ├─── Reads/Writes Task Metadata ─────► PostgreSQL
       │                                      (schedulerdb)
       │
       ├─── Publishes Tasks ────────────────► RabbitMQ Cluster
       │                                      (Quorum Queues)
       │
       └─── Checks Cluster State ───────────► Redis
                                              (Coordination)
            ▲
            │
            │  Heartbeat & Membership
            │
    ┌───────┴────────┐
    │   RabbitMQ     │
    │   Init Script  │
    │   (All Nodes)  │
    └────────────────┘

            │
            │  Consumes Tasks
            ▼
    ┌────────────────┐
    │   Fog Nodes    │  (Under Development)
    │   (workers)    │
    └────────────────┘
            │
            └─── Publishes Results ──────────► RabbitMQ
                                               (Result Queues)
```

---

## Infrastructure Components

### 1. RabbitMQ Cluster

**Configuration**: 3-node cluster with quorum queues

#### Features
- **Cluster Type**: Native RabbitMQ clustering
- **Consensus**: Raft protocol for quorum queues
- **Partition Handling**: Autoheal strategy
- **Queue Replication**: 3 replicas per quorum queue
- **Leader Distribution**: Balanced across nodes

#### Node Specifications
```yaml
rabbitmq1 (Primary):
  - Hostname: rabbitmq1
  - Management Port: 15672
  - AMQP Port: 5672
  - Role: Cluster coordinator
  - Placement: manager1

rabbitmq2 (Replica):
  - Hostname: rabbitmq2
  - Management Port: 15673
  - AMQP Port: 5672
  - Placement: manager2

rabbitmq3 (Replica):
  - Hostname: rabbitmq3
  - Management Port: 15674
  - AMQP Port: 5672
  - Placement: manager3
```

#### Health Checks
```bash
Test: rabbitmqctl status
Interval: 30s
Timeout: 10s
Retries: 3
Start Period: 40s
```

### 2. Redis

**Configuration**: Single instance with command-line configuration

#### Features
- **Persistence**: AOF with everysec fsync (via `--appendonly yes`)
- **Memory Limit**: 1GB (via `--maxmemory 1G`)
- **Eviction Policy**: allkeys-lru (via `--maxmemory-policy allkeys-lru`)
- **IO Threads**: 2
- **Max Clients**: 1,000
- **Password Protection**: Via `--requirepass` flag

#### Data Structures Used
```
rabbitmq:cluster:members            → SET (active node names)
rabbitmq:cluster:master             → STRING (master node name)
rabbitmq:node:{nodename}:heartbeat  → STRING (timestamp, TTL: 90s)
```

#### Deployment Configuration
Redis is configured entirely via command-line arguments in `compose.yml`:
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

**Note**: Redis config file (`redis.conf`) has been removed in favor of command-line configuration for simplicity and environment variable compatibility.

#### Health Checks
```bash
Test: redis-cli -a $REDIS_PASS ping
Interval: 10s
Timeout: 5s
Retries: 5
Start Period: 10s
```

### 3. PostgreSQL

**Configuration**: Single instance with custom configuration file

#### Features
- **Version**: PostgreSQL 18
- **Persistence**: WAL-based durability with fsync
- **Connection Limit**: 100 max connections
- **Memory**: 256MB shared_buffers, 64MB maintenance work mem
- **Checkpoints**: 5-minute timeout, 1GB max WAL size
- **Database**: `schedulerdb` (auto-created on first start)

#### Purpose
PostgreSQL serves as the persistent task metadata store for the scheduler:
- **Task Definitions**: Job specifications, scheduling rules, retry policies
- **Task History**: Execution logs, status transitions, timestamps
- **Scheduler State**: System state, configuration snapshots
- **Audit Trail**: User actions, system events, compliance data

#### Node Specifications
```yaml
postgres:
  - Hostname: postgres
  - Port: 5432
  - Database: schedulerdb
  - User: ${PG_USER}
  - Placement: manager1
```

#### Health Checks
```bash
Test: pg_isready -U ${PG_USER} -d schedulerdb
Interval: 10s
Timeout: 3s
Retries: 5
Start Period: 10s
```

### 4. Fog Node Workers (Under Development)

**Configuration**: Planned multi-tier worker pool

The fog node implementation is currently in development. When complete, workers will:
- Pull tasks from RabbitMQ priority queues
- Execute tasks with resource constraints (CPU/memory limits)
- Report results back to RabbitMQ result queues
- Support graceful shutdown and task preemption

---

## Prerequisites

### Software Requirements
- Docker Engine 20.10+
- Docker Compose 1.29+ (with Compose v3.8 support)
- Docker Swarm initialized
- Go 1.21+ (for local development)

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
- **Username**: `admin` (from `.env`)
- **Password**: `MQ_ADMIN_PASS` (from `.env`)

---

## Initialization Flow

### Cold Start (First Deployment)

```
┌─────────────────────────────────────────────────────────────────┐
│                     COLD START SEQUENCE                         │
└─────────────────────────────────────────────────────────────────┘

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
     │
Step 2: Redis Initialization
═════════════════════════════
     │
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
     │
Step 3: RabbitMQ1 (Primary) Initialization
═══════════════════════════════════════════
     │
     ▼
┌──────────────────┐
│ rabbitmq1 Start  │  Container starts on manager1
└────┬─────────────┘
     │
     ▼
┌──────────────────┐
│ Wait for RMQ     │  Loop: rabbitmqctl status
│ Internal Ready   │  - Retry every 2s until success
└────┬─────────────┘
     │
     ▼
┌──────────────────┐
│ Wait for Redis   │  nc -z redis 6379
│ Connectivity     │  - Max 120s (60 attempts)
└────┬─────────────┘  - Exit if timeout
     │                 ⚠️  MANDATORY: Redis must be online
     │
     ▼
┌──────────────────┐
│ Install          │  apk add --no-cache redis
│ redis-cli        │  (for coordination)
└────┬─────────────┘
     │
     ▼
┌──────────────────┐
│ Check Redis for  │  redis-cli SMEMBERS rabbitmq:cluster:members
│ Active Cluster   │
└────┬─────────────┘
     │
     ├─── Members exist? ──► NO (Cold Start)
     │                        │
     │                        ▼
     │                   ┌──────────────────┐
     │                   │ Bootstrap Master │
     │                   │ - stop_app       │
     │                   │ - reset          │
     │                   │ - start_app      │
     │                   └────┬─────────────┘
     │                        │
     │                        ▼
     │                   ┌──────────────────┐
     │                   │ Set Cluster      │
     │                   │ Master in Redis  │
     │                   │ SET master →     │
     │                   │ rabbit@rabbitmq1 │
     │                   └────┬─────────────┘
     │                        │
     │                        ▼
     │                   ┌──────────────────┐
     │                   │ Register Node    │
     │                   │ SADD members →   │
     │                   │ rabbit@rabbitmq1 │
     │                   └────┬─────────────┘
     │                        │
     │                        ▼
     │                   ┌──────────────────┐
     │                   │ Create Users     │
     │                   │ - admin (tag)    │
     │                   │ - worker1/2/3    │
     │                   └────┬─────────────┘
     │                        │
     │                        ▼
     │                   ┌──────────────────┐
     │                   │ Set Permissions  │
     │                   │ on /fog vhost    │
     │                   └────┬─────────────┘
     │                        │
     │                        ▼
     │                   ┌──────────────────┐
     │                   │ Start Heartbeat  │
     │                   │ Background Loop  │
     │                   │ (30s interval)   │
     │                   └────┬─────────────┘
     │                        │
     │                        ▼
     │                   ┌──────────────────┐
     │                   │ rabbitmq1 READY  │
     │                   │ (Cluster Master) │
     │                   └──────────────────┘
     │
     │
Step 4: RabbitMQ2 (Secondary) Initialization
═════════════════════════════════════════════
     │
     ▼
┌──────────────────┐
│ rabbitmq2 Start  │  Container starts on manager2
└────┬─────────────┘
     │
     ▼
┌──────────────────┐
│ Wait for RMQ     │  rabbitmqctl status
│ Internal Ready   │
└────┬─────────────┘
     │
     ▼
┌──────────────────┐
│ Wait for Redis   │  nc -z redis 6379
└────┬─────────────┘  ⚠️  MANDATORY: Redis must be online
     │                   (exits if not found after 120s)
     ▼
┌──────────────────┐
│ Install          │  apk add redis
│ redis-cli        │
└────┬─────────────┘
     │
     ▼
┌──────────────────┐
│ Wait for Master  │  Loop for 180s:
│ Election         │  redis-cli GET rabbitmq:cluster:master
└────┬─────────────┘  Exit if timeout
     │
     ▼
┌──────────────────┐
│ Verify Master    │  rabbitmqctl -n $MASTER status
│ Reachability     │  Retry 30 times (5s interval)
└────┬─────────────┘
     │
     ▼
┌──────────────────┐
│ Wait for Master  │  Loop until Mnesia ready:
│ Mnesia Ready     │  rabbitmqctl -n $MASTER eval
└────┬─────────────┘  'rabbit_mnesia:is_running().'
     │
     ▼
┌──────────────────┐
│ Join Cluster     │  rabbitmqctl stop_app
│                  │  rabbitmqctl reset
│                  │  rabbitmqctl join_cluster $MASTER
│                  │  rabbitmqctl start_app
└────┬─────────────┘
     │
     ▼
┌──────────────────┐
│ Verify Join      │  rabbitmqctl cluster_status
└────┬─────────────┘
     │
     ▼
┌──────────────────┐
│ Register Node    │  SADD rabbitmq:cluster:members
│ in Redis         │  rabbit@rabbitmq2
└────┬─────────────┘
     │
     ▼
┌──────────────────┐
│ Start Heartbeat  │  Background loop (30s)
└────┬─────────────┘
     │
     ▼
┌──────────────────┐
│ rabbitmq2 READY  │
│ (Cluster Member) │
└──────────────────┘


Step 5: RabbitMQ3 (Secondary) Initialization
═════════════════════════════════════════════
     │
     ▼
┌──────────────────┐
│ rabbitmq3 Start  │  [Same sequence as rabbitmq2]
└────┬─────────────┘
     │
     ▼
     ... (identical to rabbitmq2 flow)
     │
     ▼
┌──────────────────┐
│ rabbitmq3 READY  │
│ (Cluster Member) │
└──────────────────┘


Step 6: Cluster Finalization
═════════════════════════════
     │
     ▼
┌──────────────────┐
│ Verify Cluster   │  All 3 nodes report:
│ Status           │  - Running nodes: 3
└────┬─────────────┘  - Quorum queues: Online
     │
     ▼
┌──────────────────┐
│ Queue Leaders    │  Distributed across nodes
│ Rebalanced       │  (balanced locator)
└────┬─────────────┘
     │
     ▼
┌─────────────────────────────────────────┐
│          CLUSTER READY                  │
│  - PostgreSQL: Online                   │
│  - Redis: Online                        │
│  - 3 RabbitMQ nodes running             │
│  - Quorum queues replicated             │
│  - Heartbeats active                    │
│  - Redis coordination operational       │
└─────────────────────────────────────────┘
```

### Key Initialization Dependencies

#### 1. Redis Dependency (MANDATORY)
From `rabbitmq-init.sh`:
```bash
# Wait for Redis - MANDATORY for cluster coordination
until nc -z $REDIS_HOST $REDIS_PORT > /dev/null 2>&1; do
  echo "Redis not ready, waiting... (attempt $WAIT_COUNT/$((MAX_WAIT/2)))"
  ((WAIT_COUNT++))
  
  if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    echo "ERROR: Redis not reachable after $MAX_WAIT seconds"
    exit 1  # ⚠️ EXITS - Redis is mandatory
  fi
  
  sleep 1
done
```

**Why Redis is Mandatory**:
- Cluster membership tracking requires Redis `SET` data structure
- Heartbeat mechanism stores timestamps with TTL in Redis
- Master election state stored in Redis
- Without Redis, nodes cannot coordinate cluster formation or failover

---

## Failover Flow

### Scenario 1: Single Node Failure (rabbitmq2 crashes)

```
┌─────────────────────────────────────────────────────────────────┐
│               SINGLE NODE FAILURE & RECOVERY                    │
└─────────────────────────────────────────────────────────────────┘

Initial State:
═════════════
┌────────┐  ┌────────┐  ┌────────┐
│  RMQ1  │  │  RMQ2  │  │  RMQ3  │  All nodes healthy
│ MASTER │  │ MEMBER │  │ MEMBER │  Heartbeats: ✓ ✓ ✓
└────────┘  └────────┘  └────────┘

Event: rabbitmq2 Container Crash
═════════════════════════════════
Time T+0s:
    ┌────────┐            ┌────────┐
    │  RMQ1  │     ❌     │  RMQ3  │
    │ MASTER │            │ MEMBER │
    └────────┘            └────────┘
    
    - rabbitmq2 process dies
    - Heartbeat stops updating


Time T+30s (First Missed Heartbeat):
    - rabbitmq2:heartbeat key still in Redis (TTL: 90s)
    - RMQ1 and RMQ3 still see rabbitmq2 in cluster
    - Quorum queues: 2/3 nodes online (quorum maintained)


Time T+90s (Heartbeat Expiry):
    ┌─────────────────────────────┐
    │ Redis Automatic Cleanup     │
    │ - rabbitmq2:heartbeat → DEL │
    │ - SMEMBERS shows: RMQ1, RMQ3│
    └─────────────────────────────┘
    
    - Cluster recognizes node as failed
    - Queue leaders rebalance to RMQ1 and RMQ3


Time T+120s (Docker Restart Attempt #1):
    ┌───────────────────────────┐
    │ Docker Restart Policy     │
    │ - Condition: on-failure   │
    │ - Max Attempts: 3         │
    │ - Delay: 5s               │
    └───────────────────────────┘
    
    rabbitmq2 container restarts


Rejoin Sequence:
════════════════
Time T+125s:
    ┌──────────────────────┐
    │ rabbitmq2 Start      │
    │ - Wait for RabbitMQ  │
    │ - Wait for Redis     │  ⚠️ CRITICAL CHECK
    └──────────────────────┘
    
    Redis Check:
    until nc -z redis 6379; do
      # Retry for 120s
      # EXIT if Redis not found
    done


Time T+145s:
    ┌──────────────────────┐
    │ Check Cluster State  │
    └──────────────────────┘
    
    MEMBERS=$(redis-cli SMEMBERS rabbitmq:cluster:members)
    → Returns: rabbit@rabbitmq1, rabbit@rabbitmq3
    
    Decision: REJOIN existing cluster


Time T+150s:
    ┌──────────────────────────────┐
    │ Rejoin Procedure             │
    │ foreach MEMBER in MEMBERS:   │
    │   Try: join_cluster($MEMBER) │
    │   Break on success           │
    └──────────────────────────────┘
    
    Attempt 1: Join via rabbit@rabbitmq1
    ✓ SUCCESS
    
    rabbitmqctl stop_app
    rabbitmqctl reset
    rabbitmqctl join_cluster rabbit@rabbitmq1
    rabbitmqctl start_app


Time T+160s:
    ┌──────────────────────┐
    │ Rejoin Complete      │
    └──────────────────────┘
    
    - SADD rabbitmq:cluster:members rabbit@rabbitmq2
    - Start heartbeat loop
    - Quorum queues: Sync replicas from RMQ1/RMQ3


Time T+180s:
    ┌────────┐  ┌────────┐  ┌────────┐
    │  RMQ1  │  │  RMQ2  │  │  RMQ3  │  Cluster restored
    │ MASTER │  │ MEMBER │  │ MEMBER │  Heartbeats: ✓ ✓ ✓
    └────────┘  └────────┘  └────────┘


Recovery Summary:
═════════════════
Total Downtime: ~60s (worst case)
Data Loss: NONE (quorum maintained)
Impact: Minimal (2/3 nodes served requests)
```

### Scenario 2: Redis Failure During RabbitMQ Restart

```
┌─────────────────────────────────────────────────────────────────┐
│          REDIS UNAVAILABLE DURING NODE RESTART                  │
└─────────────────────────────────────────────────────────────────┘

Initial State:
═════════════
┌────────┐  ┌────────┐  ┌────────┐       ┌───────┐
│  RMQ1  │  │  RMQ2  │  │  RMQ3  │◄──────┤ Redis │
│ MASTER │  │ MEMBER │  │ MEMBER │  OK   │  ✓    │
└────────┘  └────────┘  └────────┘       └───────┘


Event: RabbitMQ2 Crashes + Redis Goes Down
════════════════════════════════════════════
Time T+0s:
┌────────┐            ┌────────┐       ┌───────┐
│  RMQ1  │     ❌     │  RMQ3  │   ❌  │ Redis │
│ MASTER │            │ MEMBER │       │  ❌   │
└────────┘            └────────┘       └───────┘


Time T+120s (RabbitMQ2 Restart Attempt):
    ┌──────────────────────┐
    │ rabbitmq2 Start      │
    │ - RabbitMQ ready     │
    │ - Check Redis...     │
    └──────────────────────┘


Redis Check Sequence:
══════════════════════
Time T+125s:
    ┌────────────────────────────┐
    │ Wait for Redis (120s max)  │
    └────────────────────────────┘
    
    WAIT_COUNT=0
    until nc -z redis 6379; do
      ((WAIT_COUNT++))
      
      if [ $WAIT_COUNT -ge 120 ]; then
        echo "ERROR: Redis not reachable"
        exit 1  # ⚠️ SCRIPT EXITS
      fi
      
      sleep 1
    done


Time T+245s (After 120s timeout):
    ┌─────────────────────────────────┐
    │ rabbitmq-init.sh EXIT           │
    │ Container stops                 │
    │ Docker restart policy triggers  │
    └─────────────────────────────────┘
    
    ⚠️ rabbitmq2 will NOT join cluster without Redis


Outcome: Cluster Degraded Until Redis Recovers
═══════════════════════════════════════════════
┌────────┐            ┌────────┐
│  RMQ1  │            │  RMQ3  │  Running with 2/3 nodes
│ MASTER │            │ MEMBER │  Quorum maintained
└────────┘            └────────┘

           rabbitmq2: Restart loop until Redis available


When Redis Recovers:
═════════════════════
Time T+300s (Redis back online):
    ┌───────┐
    │ Redis │  ✓ Recovered
    └───────┘
    
    Next rabbitmq2 restart:
    - Redis check passes
    - Reads cluster members from Redis
    - Rejoins cluster successfully


Recovery Summary:
═════════════════
Redis Downtime: Variable (until manual/automatic recovery)
RabbitMQ2 Behavior: Restart loop, exits on Redis check failure
Cluster State: 2/3 nodes operational (degraded but functional)
Impact: rabbitmq2 cannot rejoin until Redis is available
```

### Scenario 3: PostgreSQL Failure

```
┌─────────────────────────────────────────────────────────────────┐
│                  POSTGRESQL FAILURE SCENARIO                    │
└─────────────────────────────────────────────────────────────────┘

Initial State:
═════════════
┌────────┐  ┌────────┐  ┌────────┐       ┌──────────┐
│  RMQ1  │  │  RMQ2  │  │  RMQ3  │◄──────┤Postgres  │
│ MASTER │  │ MEMBER │  │ MEMBER │  OK   │    ✓     │
└────────┘  └────────┘  └────────┘       └──────────┘


Event: PostgreSQL Container Crash
═══════════════════════════════════
Time T+0s:
┌────────┐  ┌────────┐  ┌────────┐       ┌──────────┐
│  RMQ1  │  │  RMQ2  │  │  RMQ3  │   ❌  │Postgres  │
│ MASTER │  │ MEMBER │  │ MEMBER │       │    ❌    │
└────────┘  └────────┘  └────────┘       └──────────┘

Impact:
  ✓ RabbitMQ cluster: CONTINUES OPERATING (no dependency)
  ✓ Message flow: UNAFFECTED
  ✓ Quorum queues: UNAFFECTED
  ✗ Scheduler: Cannot read/write task metadata
  ✗ Task persistence: Blocked until recovery


Time T+60s (Docker Restart):
    PostgreSQL restarts (restart policy)
    
    ┌───────────────────────────┐
    │ PostgreSQL Recovery       │
    │ - Load WAL                │
    │ - Replay transactions     │
    │ - Accept connections      │
    └───────────────────────────┘


Recovery Summary:
═════════════════
PostgreSQL Downtime: ~60s (typical)
RabbitMQ Impact: NONE (independent operation)
Scheduler Impact: Cannot persist new tasks during outage
Data Loss: NONE (WAL recovery)
```

---

## Configuration

### Environment Variables

Create `.env` file in project root:

```bash
# Redis Configuration
REDIS_PASS=your_very_secure_redis_password_here

# RabbitMQ Cluster Configuration
RABBITMQ_ERLANG_COOKIE=your_secret_erlang_cookie_here

# RabbitMQ Admin User
MQ_ADMIN_USER=admin
MQ_ADMIN_PASS=your_admin_password_here

# RabbitMQ Worker Users
MQ_NODE1_WORKER=worker1
MQ_NODE1_PASS=worker1_secure_password
MQ_NODE2_WORKER=worker2
MQ_NODE2_PASS=worker2_secure_password
MQ_NODE3_WORKER=worker3
MQ_NODE3_PASS=worker3_secure_password

# PostgreSQL Configuration
PG_USER=scheduler
PG_PASS=your_postgres_password_here
```

### RabbitMQ Configuration (`rabbitmq.conf`)

```ini
# Network
listeners.tcp.default = 5672
management.tcp.port = 15672

# Cluster
cluster_partition_handling = autoheal
quorum_queue.initial_cluster_size = 3
quorum_queue.compute_checksums = true
queue_leader_locator = balanced

# Resources
vm_memory_high_watermark.relative = 0.6
disk_free_limit.absolute = 2GB

# Vhost
default_vhost = /fog

# Definitions
load_definitions = /etc/rabbitmq/definitions.json
```

### PostgreSQL Configuration (`postgresql.conf`)

```ini
# Connection settings
listen_addresses = '*'
port = 5432

# Logging
log_destination = 'stderr'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_min_duration_statement = 500

# Checkpoints / WAL
max_wal_size = '1GB'
min_wal_size = '80MB'
checkpoint_timeout = '5min'

# Memory
shared_buffers = '256MB'
work_mem = '4MB'
maintenance_work_mem = '64MB'

# Other
max_connections = 100
```

---

## Operations & Monitoring

### Essential Commands (via Makefile)

#### Quick Start
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
make redis-clear-cluster  # Clear cluster state (confirm required)
make postgres-create-db   # Create schedulerdb
make postgres-drop-db     # Drop schedulerdb (confirm required)
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
