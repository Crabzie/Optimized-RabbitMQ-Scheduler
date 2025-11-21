#!/bin/bash
set -e

echo "Waiting for RabbitMQ to be ready..."
until rabbitmqctl status > /dev/null 2>&1; do
  sleep 2
done

# Cluster join logic
if [[ -n "$CLUSTER_WITH" ]]; then
  echo "Attempting to join RabbitMQ cluster at $CLUSTER_WITH..."

  # Wait until master node is up
  until rabbitmqctl -n $CLUSTER_WITH status > /dev/null 2>&1; do
    echo "Waiting for $CLUSTER_WITH to become reachable..."
    sleep 10
  done

 # verify master has initialized cluster tables
  echo "Verifying $CLUSTER_WITH cluster readiness..."
  until rabbitmqctl -n $CLUSTER_WITH eval 'mnesia:system_info(is_running).' 2>/dev/null | grep -q "yes"; do
    echo "Master Mnesia not ready yet..."
    sleep 10
  done

  if ! rabbitmqctl cluster_status | grep -q "$CLUSTER_WITH"; then
    rabbitmqctl stop_app
    rabbitmqctl reset
    rabbitmqctl join_cluster "$CLUSTER_WITH"
    rabbitmqctl start_app
    echo "Joined cluster with $CLUSTER_WITH"
  else
    echo "Already part of the cluster"
  fi
else
  echo "This node is running as the initial cluster node"
fi

sleep 5

# Create users ONLY on initial node
if [[ -z "$CLUSTER_WITH" ]]; then
  echo "Creating users on initial node..."
  
  rabbitmqctl add_user "${MQ_ADMIN_USER}" "${MQ_ADMIN_PASS}" 2>/dev/null || echo "Admin user exists"
  rabbitmqctl set_user_tags "${MQ_ADMIN_USER}" administrator
  
  rabbitmqctl add_user "${MQ_NODE1_WORKER}" "${MQ_NODE1_PASS}" 2>/dev/null || echo "Node1 user exists"
  rabbitmqctl set_user_tags "${MQ_NODE1_WORKER}" worker
  
  rabbitmqctl add_user "${MQ_NODE2_WORKER}" "${MQ_NODE2_PASS}" 2>/dev/null || echo "Node2 user exists"
  rabbitmqctl set_user_tags "${MQ_NODE2_WORKER}" worker
  
  rabbitmqctl add_user "${MQ_NODE3_WORKER}" "${MQ_NODE3_PASS}" 2>/dev/null || echo "Node3 user exists"
  rabbitmqctl set_user_tags "${MQ_NODE3_WORKER}" worker
  
  # Set permissions
  rabbitmqctl set_permissions -p /fog "${MQ_ADMIN_USER}" ".*" ".*" ".*"
  rabbitmqctl set_permissions -p /fog "${MQ_NODE1_WORKER}" "" "amq.default" "^tasks\..*$"
  rabbitmqctl set_permissions -p /fog "${MQ_NODE2_WORKER}" "" "amq.default" "^tasks\..*$"
  rabbitmqctl set_permissions -p /fog "${MQ_NODE3_WORKER}" "" "amq.default" "^tasks\..*$"
  
  echo "Users created successfully"
else
  echo "Secondary node - users replicate from cluster"
fi

echo "RabbitMQ initialization complete"
