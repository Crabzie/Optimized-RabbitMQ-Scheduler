#!/bin/bash
set -e

REDIS_CMD="redis-cli -h $REDIS_HOST -p $REDIS_PORT -a $REDIS_PASS --no-auth-warning"

CLUSTER_MEMBERS_KEY="rabbitmq:cluster:members"
CLUSTER_MASTER_KEY="rabbitmq:cluster:master"
NODE_HEARTBEAT_KEY="rabbitmq:node:${RABBITMQ_NODENAME}:heartbeat"

echo "Waiting for RabbitMQ to be ready..."
until rabbitmqctl status > /dev/null 2>&1; do
  sleep 2
done

echo "Waiting for Redis to be ready..."
until $REDIS_CMD PING > /dev/null 2>&1; do
  echo "Redis not ready, waiting..."
  sleep 2
done

# REDIS CLUSTER STATE FUNCTIONS
register_node() {
  echo "Registering $RABBITMQ_NODENAME in Redis..."
  $REDIS_CMD SADD $CLUSTER_MEMBERS_KEY "$RABBITMQ_NODENAME"
  $REDIS_CMD SETEX $NODE_HEARTBEAT_KEY 90 "$(date +%s)"
  echo "Node registered in redis"
}

unregister_node() {
  echo "Unregistering $RABBITMQ_NODENAME from Redis..."
  $REDIS_CMD SREM $CLUSTER_MEMBERS_KEY "$RABBITMQ_NODENAME"
  $REDIS_CMD DEL $NODE_HEARTBEAT_KEY
  echo "Node unregistered from redis"
}

get_active_members() {
  # Get all members from Redis
  ALL_MEMBERS=$($REDIS_CMD SMEMBERS $CLUSTER_MEMBERS_KEY)
  
  # Check which ones have recent heartbeat
  ACTIVE_MEMBERS=""
  for member in $ALL_MEMBERS; do
    HEARTBEAT_KEY="rabbitmq:node:${member}:heartbeat"
    if $REDIS_CMD EXISTS $HEARTBEAT_KEY > /dev/null; then
      ACTIVE_MEMBERS="$ACTIVE_MEMBERS $member"
    else
      # Stale entry, remove it
      echo "Removing stale member from redis: $member"
      $REDIS_CMD SREM $CLUSTER_MEMBERS_KEY "$member"
    fi
  done
  
  echo "$ACTIVE_MEMBERS"
}

get_cluster_master() {
  MASTER=$($REDIS_CMD GET $CLUSTER_MASTER_KEY)
  
  # Verify master is still active
  if [ -n "$MASTER" ]; then
    MASTER_HEARTBEAT="rabbitmq:node:${MASTER}:heartbeat"
    if ! $REDIS_CMD EXISTS $MASTER_HEARTBEAT > /dev/null; then
      echo "Master $MASTER is stale, clearing from redis..."
      $REDIS_CMD DEL $CLUSTER_MASTER_KEY
      MASTER=""
    fi
  fi
  
  echo "$MASTER"
}

set_cluster_master() {
  local node=$1
  echo "Setting cluster master to $node..."
  $REDIS_CMD SET $CLUSTER_MASTER_KEY "$node"
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
  
  if [ -n "$ACTIVE_MEMBERS" ] && [ "$ACTIVE_MEMBERS" != "$RABBITMQ_NODENAME" ]; then
    # Other nodes exist - REJOIN
    echo "Active cluster found in Redis, attempting to rejoin..."
    
    # Try to join any active member
    for member in $ACTIVE_MEMBERS; do
      if [ "$member" != "$RABBITMQ_NODENAME" ]; then
        echo "Attempting to join via $member..."
        
        # Verify node is actually reachable
        if rabbitmqctl -n $member status > /dev/null 2>&1; then
          echo "Node $member is reachable, joining..."
          
          rabbitmqctl stop_app
          rabbitmqctl reset
          rabbitmqctl join_cluster "$member"
          rabbitmqctl start_app
          
          register_node
          echo "Rejoined existing cluster via $member"
          
          # Start heartbeat background process
          (
            while true; do
              sleep 30
              $REDIS_CMD SETEX $NODE_HEARTBEAT_KEY 90 "$(date +%s)" > /dev/null 2>&1 || true
            done
          ) &
          
          exit 0
        else
          echo "Node $member not reachable, trying next..."
        fi
      fi
    done
    
    echo "No active members reachable, falling back to bootstrap..."
  fi
  
  # No active cluster - BOOTSTRAP
  echo "No active cluster found, bootstrapping as master..."
  
  rabbitmqctl stop_app 2>/dev/null || true
  rabbitmqctl reset 2>/dev/null || true
  rabbitmqctl start_app
  
  set_cluster_master "$RABBITMQ_NODENAME"
  register_node
  
  echo "Bootstrapped as cluster master"
  
  # Start heartbeat background process
  (
    while true; do
      sleep 30
      $REDIS_CMD SETEX $NODE_HEARTBEAT_KEY 90 "$(date +%s)" > /dev/null 2>&1 || true
    done
  ) &

else
  # SECONDARY NODE LOGIC
  
  echo "This is a secondary node ($RABBITMQ_NODENAME)..."
  
  # Check if cluster exists in Redis
  if [ -z "$CURRENT_MASTER" ]; then
    echo "No master in Redis, waiting for master to initialize..."
    
    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt 36 ]; do  # Wait up to 3 minutes
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
    if rabbitmqctl -n $CURRENT_MASTER status > /dev/null 2>&1; then
      echo "Master is reachable!"
      break
    fi
    echo "Still waiting for $CURRENT_MASTER (attempt $((WAIT_COUNT+1))/24)..."
    ((WAIT_COUNT++))
    sleep 5
  done
  
  if [ $WAIT_COUNT -ge 24 ]; then
    echo "ERROR: Master $CURRENT_MASTER not reachable after 2 minutes"
    exit 1
  fi
  
  # Wait for master Mnesia to be ready
  echo "Verifying master Mnesia readiness..."
  MNESIA_WAIT=0
  until rabbitmqctl -n $CURRENT_MASTER eval 'mnesia:system_info(is_running).' 2>/dev/null | grep -q "yes"; do
    if [ $MNESIA_WAIT -ge 24 ]; then
      echo "ERROR: Master Mnesia not ready"
      exit 1
    fi
    echo "Master Mnesia not ready yet (attempt $((MNESIA_WAIT+1))/24)..."
    ((MNESIA_WAIT++))
    sleep 5
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
      $REDIS_CMD SETEX $NODE_HEARTBEAT_KEY 90 "$(date +%s)" > /dev/null 2>&1 || true
    done
  ) &
fi

sleep 5

# USER MANAGEMENT

echo "Initializing users and permissions..."

if [[ -z "$CLUSTER_WITH" ]] && [[ "$RABBITMQ_NODENAME" == "rabbit@rabbitmq1" ]]; then
  if ! rabbitmqctl list_users 2>/dev/null | grep -q "${MQ_ADMIN_USER}"; then
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
