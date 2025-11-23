# Optimized RabbitMQ Scheduler

A highly available, distributed fog computing task scheduler built on Docker Swarm with RabbitMQ clustering and Redis-based coordination.

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Infrastructure Components](#infrastructure-components)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Initialization Flow](#initialization-flow)
- [Failover Flow](#failover-flow)
- [Queue Architecture](#queue-architecture)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)

---

## Overview

This project implements an intelligent task scheduler for fog computing environments with the following features:

- **High Availability**: 3-node RabbitMQ cluster with quorum queues
- **Distributed Coordination**: Redis-based cluster membership tracking
- **Priority Scheduling**: 3-tier task prioritization system
- **Fault Tolerance**: Automatic failover and node recovery
- **Resource Awareness**: CPU/memory-constrained worker tiers

### Key Technologies

- **RabbitMQ 4.1.6**: Message queue cluster with management plugin
- **Redis 8.x**: Coordination state and cluster membership
- **Docker Swarm**: Orchestration platform
- **Alpine Linux**: Lightweight container base

---

## Architecture

### System Topology

```
┌─────────────────────────────────────────────────────────────────┐
│                      Docker Swarm Cluster                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  Manager Nodes (3)                    Worker Nodes (2)           │
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
│  └───────────────┘    │               │  │fog-node-2 │  │       │
│                       │               │  │(executor) │  │       │
│  ┌───────────────┐    │               │  └───────────┘  │       │
│  │   manager2    │    │               └─────────────────┘       │
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
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    fog-network (overlay)
```

### Component Distribution

| Node | Role | Services | Ports |
|------|------|----------|-------|
| **manager1** | Manager | rabbitmq1 (master), redis | 15672, 6379 |
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

**Configuration**: Single instance with AOF persistence

#### Features
- **Persistence**: AOF with everysec fsync
- **Memory Limit**: 512MB
- **Eviction Policy**: allkeys-lru
- **IO Threads**: 4 (with read support)
- **Max Clients**: 10,000
- **Active Defragmentation**: Enabled

#### Data Structures Used
```
rabbitmq:cluster:members            → SET (active node names)
rabbitmq:cluster:master             → STRING (master node name)
rabbitmq:node:{nodename}:heartbeat  → STRING (timestamp, TTL: 90s)
```

#### Security
- Password authentication required
- Disabled commands: `FLUSHDB`, `FLUSHALL`, `CONFIG`

#### Health Checks
```bash
Test: redis-cli -a $REDIS_PASS ping
Interval: 10s
Timeout: 5s
Retries: 5
Start Period: 10s
```

### 3. Fog Node Workers

**Configuration**: 3 worker tiers with resource constraints

#### Worker Specifications
```yaml
fog-node-1 (Tier 1 - Light):
  CPU: 0.5 cores
  Memory: 512MB
  Placement: fog==1 label

fog-node-2 (Tier 2 - Medium):
  CPU: 0.75 cores
  Memory: 768MB
  Placement: fog==3 label


fog-node-3 (Tier 3 - Heavy):
  CPU: 1.0 cores
  Memory: 1024MB
  Placement: fog==3 label
```

---

## Prerequisites

### Software Requirements
- Docker Engine 20.10+
- Docker Compose 1.29+ (with Compose v3.8 support)
- Docker Swarm initialized

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
```bash
# Choose a manager host (out of the 3 manager nodes) to be swarm master manager and label it as manager-master
docker node update --label-add manager-master {hostname}
# Choose a different manager host (out of the 2 manager nodes left) to be swarm manager replica1 and label it as manager-rep1
docker node update --label-add manager-rep1 {hostname}
# Label the last manage host to be swarm manager replica2 and label it as manager-rep2
docker node update --label-add manager-rep2 {hostname}
# On your a worker host label the swarm node as worker1
docker node update --label-add worker1 {hostname}
# On your second worker host label the swarm node as worker2
docker node update --label-add worker2 {hostname}
```

### 3. Deploy Stack
Commands here are executed from within the master manager
```bash
# Clone repository
git clone https://github.com/Crabzie/Optimized-RabbitMQ-Scheduler.git
cd Optimized-RabbitMQ-Scheduler

# Update .env file (see Prerequisites) or skip this if you use the provided .env file
nano .env

# Deploy stack
make up
```

### 4. Verify Deployment
Commands here are executed from within the master manager
```bash
# Check services
make status

# Check RabbitMQ cluster status
make rabbitmq

# Check Redis connectivity
make redis
```

### 5. Access Management UI
- RabbitMQ1: http://manager1-ip:15672
- RabbitMQ2: http://manager2-ip:15673
- RabbitMQ3: http://manager3-ip:15674
- Username: `admin` (from `.env`)
- Password: `MQ_ADMIN_PASS` (from `.env`)

---

## Initialization Flow

### Cold Start (First Deployment)

```
┌─────────────────────────────────────────────────────────────────┐
│                     COLD START SEQUENCE                          │
└─────────────────────────────────────────────────────────────────┘

Step 1: Redis Initialization
════════════════════════════
┌──────────┐
│  Redis   │  Starts on manager1
│  Start   │  - Loads redis.conf
└────┬─────┘  - Binds to 0.0.0.0:6379
     │        - AOF recovery (if exists)
     │        - Ready to accept connections
     ▼
┌──────────┐
│  Redis   │  Health check passes
│  Ready   │  - redis-cli ping → PONG
└────┬─────┘
     │
     │
Step 2: RabbitMQ1 (Primary) Initialization
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
└────┬─────────────┘ - Exit if timeout
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
Step 3: RabbitMQ2 (Secondary) Initialization
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
└────┬─────────────┘
     │
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
└────┬─────────────┘ Exit if timeout
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
└────┬─────────────┘ 'rabbit_mnesia:is_running().'
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


Step 4: RabbitMQ3 (Secondary) Initialization
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


Step 5: Cluster Finalization
═════════════════════════════
     │
     ▼
┌──────────────────┐
│ Verify Cluster   │  All 3 nodes report:
│ Status           │  - Running nodes: 3
└────┬─────────────┘ - Quorum queues: Online
     │
     ▼
┌──────────────────┐
│ Queue Leaders    │  Distributed across nodes
│ Rebalanced       │  (balanced locator)
└────┬─────────────┘
     │
     ▼
┌──────────────────────────────────────┐
│          CLUSTER READY                │
│  - 3 nodes running                    │
│  - Quorum queues replicated           │
│  - Heartbeats active                  │
│  - Redis coordination operational     │
└──────────────────────────────────────┘
```

### Key Initialization Points

#### 1. Primary Node Bootstrap (rabbitmq1) Snippet
```bash
# Check for existing cluster
MEMBERS=$(redis-cli -h redis -p 6379 -a "$REDIS_PASS" SMEMBERS "$CLUSTER_MEMBERS_KEY")

if [ -z "$MEMBERS" ]; then
  # No active cluster - bootstrap as master
  rabbitmqctl stop_app
  rabbitmqctl reset
  rabbitmqctl start_app
  
  # Register in Redis
  redis-cli SET rabbitmq:cluster:master "rabbit@rabbitmq1"
  redis-cli SADD rabbitmq:cluster:members "rabbit@rabbitmq1"
  
  # Create users on first boot
  create_users
fi
```

#### 2. Secondary Node Join (rabbitmq2/3) Snippet
```bash
# Wait for master election
MASTER=$(wait_for_master 180)

# Verify master reachability
verify_master_reachable "$MASTER"

# Wait for master Mnesia
wait_for_master_mnesia "$MASTER"

# Join cluster
rabbitmqctl stop_app
rabbitmqctl reset
rabbitmqctl join_cluster "$MASTER"
rabbitmqctl start_app

# Register in Redis
redis-cli SADD rabbitmq:cluster:members "rabbit@rabbitmq2"
```

#### 3. Heartbeat Loop (All Nodes) Snippet
```bash
# Background process
while true; do
  redis-cli SETEX "rabbitmq:node:${RABBITMQ_NODENAME}:heartbeat" 90 "$(date +%s)"
  sleep 30
done
```

---

## Failover Flow

### Scenario 1: Single Node Failure (rabbitmq2 crashes)

```
┌─────────────────────────────────────────────────────────────────┐
│               SINGLE NODE FAILURE & RECOVERY                     │
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
    │ - Wait for Redis     │
    └──────────────────────┘


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

### Scenario 2: Master Node Failure (rabbitmq1 crashes)

```
┌─────────────────────────────────────────────────────────────────┐
│              MASTER NODE FAILURE & RECOVERY                      │
└─────────────────────────────────────────────────────────────────┘

Initial State:
═════════════
┌────────┐  ┌────────┐  ┌────────┐
│  RMQ1  │  │  RMQ2  │  │  RMQ3  │
│ MASTER │  │ MEMBER │  │ MEMBER │
└────────┘  └────────┘  └────────┘

Redis State:
  rabbitmq:cluster:master = "rabbit@rabbitmq1"
  rabbitmq:cluster:members = {rabbitmq1, rabbitmq2, rabbitmq3}


Event: rabbitmq1 Crash (Master Node)
═════════════════════════════════════
Time T+0s:
         ❌        ┌────────┐  ┌────────┐
                   │  RMQ2  │  │  RMQ3  │
                   │ MEMBER │  │ MEMBER │
                   └────────┘  └────────┘

    - rabbitmq1 process dies
    - Management UI (15672) unreachable
    - AMQP connections to RMQ1 drop


Time T+30s:
    ┌────────────────────────────────────┐
    │ Client Failover                    │
    │ - AMQP clients detect connection   │
    │   failure to rabbitmq1:5672        │
    │ - Auto-reconnect to rabbitmq2:5672 │
    │   or rabbitmq3:5672                │
    └────────────────────────────────────┘


Time T+90s (Heartbeat Expiry):
    ┌─────────────────────────────────┐
    │ Redis Cleanup                   │
    │ - DEL rabbitmq1:heartbeat       │
    │ - SMEMBERS → {RMQ2, RMQ3}       │
    │ - master key still = rabbitmq1  │
    └─────────────────────────────────┘
    
    Note: No automatic master re-election
          (master key is just metadata)


Time T+120s (Docker Restart):
    rabbitmq1 container restarts on manager1


Rejoin Sequence:
════════════════
Time T+125s:
    ┌──────────────────────┐
    │ rabbitmq1 Start      │
    │ - RabbitMQ ready     │
    │ - Redis connected    │
    └──────────────────────┘


Time T+145s:
    ┌──────────────────────────────┐
    │ Check Redis Cluster State    │
    └──────────────────────────────┘
    
    MEMBERS=$(redis-cli SMEMBERS rabbitmq:cluster:members)
    → Returns: rabbit@rabbitmq2, rabbit@rabbitmq3
    
    Decision: REJOIN (not bootstrap)
    Reason: Active members exist


Time T+150s:
    ┌──────────────────────────────┐
    │ Rejoin via RMQ2 or RMQ3      │
    └──────────────────────────────┘
    
    Attempt: Join via rabbit@rabbitmq2
    
    rabbitmqctl stop_app
    rabbitmqctl reset
    rabbitmqctl join_cluster rabbit@rabbitmq2
    rabbitmqctl start_app
    
    ✓ SUCCESS


Time T+160s:
    ┌────────────────────────────────┐
    │ Role Adjustment                │
    └────────────────────────────────┘
    
    - rabbitmq1 rejoins as MEMBER (not master)
    - Redis: SADD members rabbit@rabbitmq1
    - Start heartbeat
    - Sync quorum queue replicas


Time T+180s:
    ┌────────┐  ┌────────┐  ┌────────┐
    │  RMQ1  │  │  RMQ2  │  │  RMQ3  │
    │ MEMBER │  │ MEMBER │  │ MEMBER │  All nodes equal
    └────────┘  └────────┘  └────────┘
    
    Note: "Master" designation in Redis is now
          just coordination metadata. All nodes
          are equal in RabbitMQ cluster.


Recovery Summary:
═════════════════
Total Downtime: ~60s for rabbitmq1
Data Loss: NONE (quorum maintained)
Impact: Clients failed over to RMQ2/RMQ3
Special: rabbitmq1 loses "master" role,
         but cluster remains functional
```

### Scenario 3: Network Partition (Split Brain)

```
┌─────────────────────────────────────────────────────────────────┐
│              NETWORK PARTITION & AUTOHEAL                        │
└─────────────────────────────────────────────────────────────────┘

Initial State:
═════════════
┌────────┐  ┌────────┐  ┌────────┐
│  RMQ1  │──│  RMQ2  │──│  RMQ3  │
│ MASTER │  │ MEMBER │  │ MEMBER │  All connected
└────────┘  └────────┘  └────────┘
     │           │           │
     └───────────┴───────────┘
         fog-network


Event: Network Partition (RMQ1 isolated)
═════════════════════════════════════════
Time T+0s:
┌────────┐     ╳╳╳╳╳╳     ┌────────┐  ┌────────┐
│  RMQ1  │     ╳╳╳╳╳╳     │  RMQ2  │──│  RMQ3  │
│ ALONE  │     ╳╳╳╳╳╳     │ MEMBER │  │ MEMBER │
└────────┘     ╳╳╳╳╳╳     └────────┘  └────────┘
                Network Partition


Partition Detection:
═════════════════════
Time T+10s:
    ┌──────────────────────────────┐
    │ RabbitMQ Detects Partition   │
    │ - Node_down events           │
    │ - Cluster status changes     │
    └──────────────────────────────┘
    
    RMQ1 sees: {down, [rabbit@rabbitmq2, rabbit@rabbitmq3]}
    RMQ2 sees: {down, [rabbit@rabbitmq1]}
    RMQ3 sees: {down, [rabbit@rabbitmq1]}


Autoheal Strategy (config: autoheal)
═════════════════════════════════════
Time T+15s:
    ┌─────────────────────────────────┐
    │ Autoheal Coordinator Election   │
    │ - Oldest node becomes leader    │
    │ - Leader: RMQ1 (rabbit@rabbitmq1)│
    └─────────────────────────────────┘


Time T+20s:
    ┌─────────────────────────────────┐
    │ Partition Winner Selection      │
    │ - Winner: Partition with most   │
    │   nodes = {RMQ2, RMQ3}          │
    │ - Loser: {RMQ1}                 │
    └─────────────────────────────────┘


Time T+25s:
    ┌─────────────────────────────────┐
    │ Autoheal Actions                │
    │ - Losing partition restarts     │
    │   all nodes (RMQ1)              │
    │ - Winning partition continues   │
    │   (RMQ2, RMQ3)                  │
    └─────────────────────────────────┘
    
    RMQ1 executes:
      rabbitmqctl stop_app
      rabbitmqctl start_app


Time T+30s (Network Heals):
╔════════════════════════════════════╗
║   Network Restored                 ║
╚════════════════════════════════════╝
┌────────┐  ┌────────┐  ┌────────┐
│  RMQ1  │──│  RMQ2  │──│  RMQ3  │
│RESTART │  │ MEMBER │  │ MEMBER │
└────────┘  └────────┘  └────────┘


Rejoin After Autoheal:
══════════════════════
Time T+35s:
    RMQ1 rabbitmq-init.sh detects:
    - Redis members: {RMQ2, RMQ3}
    - Initiates REJOIN procedure
    
    rabbitmqctl stop_app
    rabbitmqctl reset
    rabbitmqctl join_cluster rabbit@rabbitmq2
    rabbitmqctl start_app


Time T+45s:
    ┌────────┐  ┌────────┐  ┌────────┐
    │  RMQ1  │──│  RMQ2  │──│  RMQ3  │
    │ MEMBER │  │ MEMBER │  │ MEMBER │  Cluster healed
    └────────┘  └────────┘  └────────┘


Recovery Summary:
═════════════════
Detection Time: ~10s
Autoheal Time: ~15s
Rejoin Time: ~20s
Total Recovery: ~45s
Data Loss: Messages on RMQ1 during partition
           (quorum queues on RMQ2/RMQ3 preserved)
```

### Scenario 4: Redis Failure

```
┌─────────────────────────────────────────────────────────────────┐
│                  REDIS FAILURE SCENARIO                          │
└─────────────────────────────────────────────────────────────────┘

Initial State:
═════════════
┌────────┐  ┌────────┐  ┌────────┐       ┌───────┐
│  RMQ1  │  │  RMQ2  │  │  RMQ3  │◄──────┤ Redis │
│ MASTER │  │ MEMBER │  │ MEMBER │  OK   │ (M1)  │
└────────┘  └────────┘  └────────┘       └───────┘


Event: Redis Container Crash
══════════════════════════════
Time T+0s:
┌────────┐  ┌────────┐  ┌────────┐       ┌───────┐
│  RMQ1  │  │  RMQ2  │  │  RMQ3  │   ❌   │ Redis │
│ MASTER │  │ MEMBER │  │ MEMBER │        │  ❌   │
└────────┘  └────────┘  └────────┘       └───────┘

Impact:
  ✓ RabbitMQ cluster: CONTINUES OPERATING
  ✓ Message flow: UNAFFECTED
  ✓ Quorum queues: UNAFFECTED
  ✗ Heartbeat updates: FAIL (background)
  ✗ New node joins: BLOCKED


Time T+30s (Heartbeat Failure):
    ┌─────────────────────────────────┐
    │ Heartbeat Background Process    │
    │ - Attempts: SETEX heartbeat     │
    │ - Result: Connection refused    │
    │ - Action: Retry in 30s          │
    └─────────────────────────────────┘
    
    Note: Does NOT crash RabbitMQ containers
          (heartbeat runs in background)


Time T+60s (Docker Restart):
    Redis restarts (restart policy)
    
    ┌───────────────────────────┐
    │ Redis Recovery            │
    │ - Load AOF file           │
    │ - Replay operations       │
    │ - Accept connections      │
    └───────────────────────────┘


Time T+90s (Heartbeats Resume):
    All RabbitMQ nodes reconnect:
    - SETEX heartbeat succeeds
    - Cluster membership restored
    
    ┌────────┐  ┌────────┐  ┌────────┐       ┌───────┐
    │  RMQ1  │  │  RMQ2  │  │  RMQ3  │◄──────┤ Redis │
    │ MASTER │  │ MEMBER │  │ MEMBER │  ✓    │  ✓    │
    └────────┘  └────────┘  └────────┘       └───────┘


Recovery Summary:
═════════════════
RabbitMQ Downtime: 0s (unaffected)
Redis Downtime: ~60s
Data Loss: NONE (AOF persistence)
Impact: Coordination unavailable, but
        message flow continues normally
```

---

## Queue Architecture

### Exchange Topology

```
                    RabbitMQ Virtual Host: /fog
┌─────────────────────────────────────────────────────────────┐
│                                                               │
│  ┌──────────────┐      ┌──────────────┐      ┌────────────┐│
│  │tasks.direct  │      │system.fanout │      │results.    ││
│  │   (direct)   │      │   (fanout)   │      │   topic    ││
│  └──────┬───────┘      └──────┬───────┘      └─────┬──────┘│
│         │                     │                     │       │
│         │ Routing Keys:       │ Broadcasts:         │ Keys: │
│         │ - high_priority     │ - All system msgs   │ - *.* │
│         │ - normal            │                     │       │
│         │ - low_priority      │                     │       │
│         │                     │                     │       │
│         ▼                     ▼                     ▼       │
│  ┌─────────────┐      ┌─────────────┐      ┌─────────────┐│
│  │tasks.high   │      │System Queues│      │results.     ││
│  │tasks.normal │      │             │      │  success    ││
│  │tasks.low    │      │             │      │results.     ││
│  └─────────────┘      └─────────────┘      │  failed     ││
│                                             └─────────────┘│
│                                                             │
│  ┌──────────────┐                   ┌────────────┐        │
│  │metrics.topic │                   │    dlx     │        │
│  │   (topic)    │                   │  (topic)   │        │
│  └──────┬───────┘                   └─────┬──────┘        │
│         │ Keys:                            │               │
│         │ - metrics.node.#                 │ All failed    │
│         │                                  │ messages      │
│         ▼                                  ▼               │
│  ┌─────────────┐                   ┌─────────────┐        │
│  │metrics.node │                   │     dlq     │        │
│  └─────────────┘                   └─────────────┘        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Queue Specifications

#### Task Queues (Quorum Type)
```json
{
  "name": "tasks.high_priority",
  "type": "quorum",
  "durable": true,
  "arguments": {
    "x-max-length": 10000,
    "x-overflow": "reject-publish",
    "x-delivery-limit": 3,
    "x-dead-letter-exchange": "dlx",
    "x-dead-letter-routing-key": "task.failed"
  }
}
```

**Features**:
- **Max capacity**: 10,000 messages
- **Overflow**: Reject new messages when full
- **Retry limit**: 3 delivery attempts
- **DLX**: Failed messages → Dead Letter Exchange

**Priority Levels**:
1. **high_priority**: Time-sensitive tasks
2. **normal**: Standard tasks
3. **low_priority**: Batch/background tasks

#### Result Queues (Quorum Type)
```json
{
  "name": "results.success",
  "type": "quorum",
  "durable": true,
  "arguments": {
    "x-max-length": 50000,
    "x-overflow": "drop-head"
  }
}
```

**Features**:
- **Max capacity**: 50,000 results
- **Overflow**: Drop oldest results when full
- **Routing**: Topic-based (`results.success.*`, `results.failed.*`)

#### Metrics Queue (Quorum Type)
```json
{
  "name": "metrics.node",
  "type": "quorum",
  "durable": true,
  "arguments": {
    "x-max-length": 100000,
    "x-overflow": "drop-head"
  }
}
```

**Features**:
- **Max capacity**: 100,000 metrics
- **Overflow**: Drop oldest metrics
- **Routing**: `metrics.node.#` (wildcard)

#### Dead Letter Queue
```json
{
  "name": "dlq",
  "type": "quorum",
  "durable": true
}
```

**Purpose**: Capture messages that:
- Exceeded retry limit (3 attempts)
- Rejected by consumers
- Expired (if TTL set)

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

### Redis Configuration (`redis.conf`)

```ini
# Network
bind 0.0.0.0
port 6379

# Memory
maxmemory 512mb
maxmemory-policy allkeys-lru

# Persistence
appendonly yes
appendfsync everysec
save ""

# Performance
io-threads 4
io-threads-do-reads yes

# Security
requirepass ${REDIS_PASS}
rename-command FLUSHDB ""
rename-command FLUSHALL ""
rename-command CONFIG ""
```
