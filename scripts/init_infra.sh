#!/bin/bash
set -e

CLUSTER_MEMBERS_KEY="rabbitmq:cluster:members"
CLUSTER_MASTER_KEY="rabbitmq:cluster:master"
NODE_HEARTBEAT_KEY="rabbitmq:node:${RABBITMQ_NODENAME}:heartbeat"

echo "Waiting for RabbitMQ to be ready..."
until rabbitmqctl status >/dev/null 2>&1; do
  sleep 2
done

echo "Waiting for Redis to be ready at $REDIS_HOST:$REDIS_PORT..."

WAIT_COUNT=0
MAX_WAIT=120

until nc -z $REDIS_HOST $REDIS_PORT >/dev/null 2>&1; do
  echo "Redis not ready, waiting... (attempt $WAIT_COUNT/$((MAX_WAIT / 2)))"
  ((WAIT_COUNT++))

  if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    echo "ERROR: Redis not reachable after $MAX_WAIT seconds"
    echo "Debugging info:"
    echo "  REDIS_HOST: $REDIS_HOST"
    echo "  REDIS_PORT: $REDIS_PORT"
    echo "  Testing DNS:"
    nslookup $REDIS_HOST || echo "  DNS lookup failed"
    exit 1
  fi

  sleep 1
done

echo "Redis is reachable!"

# Now install redis-cli for coordinator operations
echo "Installing redis-cli for coordinator..."
apk add --no-cache redis >/dev/null 2>&1 || true

REDIS_CMD="redis-cli -h $REDIS_HOST -p $REDIS_PORT -a $REDIS_PASS --no-auth-warning"

# REDIS RETRY WRAPPER
redis_retry() {
  local max_attempts=10
  local attempt=1
  local delay=3

  while [ $attempt -le $max_attempts ]; do
    if $REDIS_CMD "$@" 2>/dev/null; then
      return 0
    fi

    echo "Redis command failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
    sleep $delay
    ((attempt++))
  done

  echo "ERROR: Redis command failed after $max_attempts attempts"
  return 1
}

# REDIS CLUSTER STATE FUNCTIONS
register_node() {
  echo "Registering $RABBITMQ_NODENAME in Redis..."
  redis_retry SADD $CLUSTER_MEMBERS_KEY "$RABBITMQ_NODENAME" || exit 1
  redis_retry SETEX $NODE_HEARTBEAT_KEY 90 "$(date +%s)" || exit 1
  echo "Node registered in redis"
}

unregister_node() {
  echo "Unregistering $RABBITMQ_NODENAME from Redis..."
  redis_retry SREM $CLUSTER_MEMBERS_KEY "$RABBITMQ_NODENAME"
  redis_retry DEL $NODE_HEARTBEAT_KEY
  echo "Node unregistered from redis"
}

get_active_members() {
  ALL_MEMBERS=$(redis_retry SMEMBERS $CLUSTER_MEMBERS_KEY) || {
    echo "ERROR: Cannot get cluster members from Redis"
    return 1
  }

  ACTIVE_MEMBERS=""
  for member in $ALL_MEMBERS; do
    HEARTBEAT_KEY="rabbitmq:node:${member}:heartbeat"
    if redis_retry EXISTS $HEARTBEAT_KEY >/dev/null 2>&1; then
      ACTIVE_MEMBERS="$ACTIVE_MEMBERS $member"
    else
      echo "Removing stale member: $member"
      redis_retry SREM $CLUSTER_MEMBERS_KEY "$member" || true
    fi
  done

  echo "$ACTIVE_MEMBERS"
}

get_cluster_master() {
  MASTER=$(redis_retry GET $CLUSTER_MASTER_KEY) || {
    echo "ERROR: Cannot get master from Redis"
    return 1
  }

  if [ -n "$MASTER" ]; then
    MASTER_HEARTBEAT="rabbitmq:node:${MASTER}:heartbeat"
    if ! redis_retry EXISTS $MASTER_HEARTBEAT >/dev/null 2>&1; then
      echo "Master $MASTER is stale, clearing..."
      redis_retry DEL $CLUSTER_MASTER_KEY || true
      MASTER=""
    fi
  fi

  echo "$MASTER"
}

set_cluster_master() {
  local node=$1
  echo "Setting cluster master to $node..."
  redis_retry SET $CLUSTER_MASTER_KEY "$node" || exit 1
  echo "Master set in redis"
}

cleanup_on_exit() {
  echo "Cleanup triggered..."
  unregister_node
  exit 0
}

trap cleanup_on_exit SIGTERM SIGINT

# CLUSTER LOGIC WITH REDIS COORDINATION

echo "Checking cluster state in Redis..."
ACTIVE_MEMBERS=$(get_active_members)
CURRENT_MASTER=$(get_cluster_master)

echo "Active members in Redis: $ACTIVE_MEMBERS"
echo "Current master in Redis: $CURRENT_MASTER"

if [[ -z "$CLUSTER_WITH" ]]; then
  # PRIMARY NODE (rabbitmq1) LOGIC

  echo "This is rabbitmq1 (primary node candidate)..."

  # Filter out THIS node from active members to find OTHER nodes
  OTHER_MEMBERS=""
  for member in $ACTIVE_MEMBERS; do
    if [ "$member" != "$RABBITMQ_NODENAME" ]; then
      OTHER_MEMBERS="$OTHER_MEMBERS $member"
    fi
  done
  OTHER_MEMBERS=$(echo "$OTHER_MEMBERS" | xargs)

  if [ -n "$OTHER_MEMBERS" ]; then
    # Other nodes exist - REJOIN
    echo "Other active members found in Redis: $OTHER_MEMBERS"
    echo "Attempting to rejoin..."

    REJOINED=false
    # Try to join any active member
    for member in $OTHER_MEMBERS; do
      echo "Attempting to join via $member..."

      # Verify node is actually reachable
      if rabbitmqctl -n $member status >/dev/null 2>&1; then
        echo "Node $member is reachable, joining..."

        rabbitmqctl stop_app
        rabbitmqctl reset
        rabbitmqctl join_cluster "$member"
        rabbitmqctl start_app

        set_cluster_master "$member"
        register_node
        echo "Rejoined existing cluster via $member"

        REJOINED=true
        break
      else
        echo "Node $member not reachable, trying next..."
      fi
    done

    if [ "$REJOINED" = false ]; then
      echo "No other members reachable, registering as standalone master..."
      set_cluster_master "$RABBITMQ_NODENAME"
      register_node
    fi
  else
    # No other active members - this is FIRST BOOT or sole survivor
    # DO NOT reset! RabbitMQ already started with definitions loaded
    echo "No other active cluster members, registering as master..."

    set_cluster_master "$RABBITMQ_NODENAME"
    register_node

    echo "Registered as cluster master"
  fi

  # Start heartbeat background process
  (
    while true; do
      sleep 30
      $REDIS_CMD SETEX $NODE_HEARTBEAT_KEY 90 "$(date +%s)" >/dev/null 2>&1 || true
    done
  ) &

else
  # SECONDARY NODE LOGIC

  echo "This is a secondary node ($RABBITMQ_NODENAME)..."

  # Check if cluster exists in Redis
  if [ -z "$CURRENT_MASTER" ]; then
    echo "No master in Redis, waiting for master to initialize..."

    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt 36 ]; do # Wait up to 3 minutes
      sleep 5
      ((WAIT_COUNT++))

      CURRENT_MASTER=$(get_cluster_master)
      if [ -n "$CURRENT_MASTER" ]; then
        echo "Master appeared: $CURRENT_MASTER"
        break
      fi

      echo "Still waiting for master (attempt $WAIT_COUNT/36)..."
    done

    if [ -z "$CURRENT_MASTER" ]; then
      echo "ERROR: No master after 3 minutes, cannot join cluster"
      exit 1
    fi
  fi

  echo "Master node is: $CURRENT_MASTER"
  echo "Attempting to join cluster via $CURRENT_MASTER..."

  # Wait for master to be reachable
  echo "Waiting for master to be reachable..."
  WAIT_COUNT=0
  while [ $WAIT_COUNT -lt 24 ]; do
    if rabbitmqctl -n $CURRENT_MASTER status >/dev/null 2>&1; then
      echo "Master is reachable!"
      break
    fi
    echo "Still waiting for $CURRENT_MASTER (attempt $((WAIT_COUNT + 1))/24)..."
    ((WAIT_COUNT++))
    sleep 5
  done

  if [ $WAIT_COUNT -ge 24 ]; then
    echo "ERROR: Master $CURRENT_MASTER not reachable after 2 minutes"
    exit 1
  fi

  # Wait for master to be fully ready (Khepri migration complete)
  echo "Verifying master readiness..."
  MNESIA_WAIT=0
  until rabbitmqctl -n "$CURRENT_MASTER" cluster_status >/dev/null 2>/dev/null; do
    if [ $MNESIA_WAIT -ge 30 ]; then
      echo "ERROR: Master not cluster-ready after 5 minutes"
      rabbitmq-diagnostics -n "$CURRENT_MASTER" status || true
      exit 1
    fi
    echo "Master not ready yet (attempt $((MNESIA_WAIT + 1))/30)..."
    ((MNESIA_WAIT++))
    sleep 10 # Longer interval
  done

  # Join cluster
  if ! rabbitmqctl cluster_status 2>/dev/null | grep -q "$CURRENT_MASTER"; then
    echo "Not yet in cluster, joining..."
    rabbitmqctl stop_app 2>/dev/null || true
    rabbitmqctl reset 2>/dev/null || true
    rabbitmqctl join_cluster "$CURRENT_MASTER"
    rabbitmqctl start_app

    register_node
    echo "Joined cluster"
  else
    register_node
    echo "Already part of the cluster"
  fi

  # Start heartbeat background process
  (
    while true; do
      sleep 30
      $REDIS_CMD SETEX $NODE_HEARTBEAT_KEY 90 "$(date +%s)" >/dev/null 2>&1 || true
    done
  ) &
fi

sleep 5

# USER MANAGEMENT

echo "Initializing users and permissions..."

if [[ -z "$CLUSTER_WITH" ]] && [[ "$RABBITMQ_NODENAME" == "rabbit@rabbitmq1" ]]; then
  if ! rabbitmqctl list_users 2>/dev/null | grep -q "${MQ_ADMIN_USER}"; then
    # Apply definitions after cluster is ready
    echo "Applying RabbitMQ definitions..."
    rabbitmqctl import_definitions /etc/rabbitmq/definitions.json
    echo "Definitions imported"

    sleep 5

    echo "First boot detected, creating users..."

    rabbitmqctl add_user "${MQ_ADMIN_USER}" "${MQ_ADMIN_PASS}" 2>/dev/null || true
    rabbitmqctl set_user_tags "${MQ_ADMIN_USER}" administrator

    rabbitmqctl add_user "${MQ_NODE1_WORKER}" "${MQ_NODE1_PASS}" 2>/dev/null || true
    rabbitmqctl set_user_tags "${MQ_NODE1_WORKER}" worker

    rabbitmqctl add_user "${MQ_NODE2_WORKER}" "${MQ_NODE2_PASS}" 2>/dev/null || true
    rabbitmqctl set_user_tags "${MQ_NODE2_WORKER}" worker

    rabbitmqctl add_user "${MQ_NODE3_WORKER}" "${MQ_NODE3_PASS}" 2>/dev/null || true
    rabbitmqctl set_user_tags "${MQ_NODE3_WORKER}" worker

    rabbitmqctl set_permissions -p /fog "${MQ_ADMIN_USER}" ".*" ".*" ".*"
    rabbitmqctl set_permissions -p /fog "${MQ_NODE1_WORKER}" "" "amq.default" "^tasks\..*$"
    rabbitmqctl set_permissions -p /fog "${MQ_NODE2_WORKER}" "" "amq.default" "^tasks\..*$"
    rabbitmqctl set_permissions -p /fog "${MQ_NODE3_WORKER}" "" "amq.default" "^tasks\..*$"

    echo "Users created"
  else
    echo "Users already exist"
  fi
else
  echo "Secondary node or rejoin - users replicate from cluster"
fi

echo "RabbitMQ initialization complete"

# Keep process alive to maintain heartbeat
wait
