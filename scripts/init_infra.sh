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
		debug_dns
		exit 1
	fi

	sleep 1
done

echo "Redis is reachable!"

# Now install redis-cli for coordinator operations
echo "Installing redis-cli for coordinator..."
apk add --no-cache redis >/dev/null 2>&1 || true

REDIS_CMD="redis-cli -h $REDIS_HOST -p $REDIS_PORT -a $REDIS_PASS --no-auth-warning"

debug_dns() {
	echo "Debugging info:"
	echo "  REDIS_HOST: $REDIS_HOST"
	echo "  REDIS_PORT: $REDIS_PORT"
	echo "  Testing DNS:"
	nslookup $REDIS_HOST || echo "  DNS lookup failed"
}

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

cleanup_on_exit() {
	echo "Cleanup triggered..."
	unregister_node
	exit 0
}

trap cleanup_on_exit SIGTERM SIGINT

# Single Node Logic
echo "This is a single node setup or single master..."

# Verify if we should be master in Redis just for visibility
redis_retry SET $CLUSTER_MASTER_KEY "$RABBITMQ_NODENAME" || exit 1
register_node

echo "Registered as cluster master/single node"

# Start heartbeat background process
(
	while true; do
		sleep 30
		$REDIS_CMD SETEX $NODE_HEARTBEAT_KEY 90 "$(date +%s)" >/dev/null 2>&1 || true
	done
) &

sleep 5

# USER MANAGEMENT

echo "Initializing users and permissions..."

if ! rabbitmqctl list_users 2>/dev/null | grep -q "${MQ_ADMIN_USER}"; then
	# Apply definitions after cluster is ready
	echo "Applying RabbitMQ definitions..."
	rabbitmqctl import_definitions /etc/rabbitmq/definitions.json
	echo "Definitions imported"

	sleep 5

	echo "First boot detected, creating users..."

	rabbitmqctl add_user "${MQ_ADMIN_USER}" "${MQ_ADMIN_PASS}" 2>/dev/null || true
	rabbitmqctl set_user_tags "${MQ_ADMIN_USER}" administrator

	rabbitmqctl add_user "${MQ_WORKER_USER}" "${MQ_WORKER_PASS}" 2>/dev/null || true
	rabbitmqctl set_user_tags "${MQ_WORKER_USER}" worker

	echo "Creating /fog vhost..."
	rabbitmqctl add_vhost /fog 2>/dev/null || true
	rabbitmqctl set_vhost_limits -p /fog '{"max-connections": 1000, "max-queues": 500}' 2>/dev/null || true

	rabbitmqctl set_permissions -p /fog "${MQ_ADMIN_USER}" ".*" ".*" ".*"
	# All workers use the same user now
	rabbitmqctl set_permissions -p /fog "${MQ_WORKER_USER}" "" "amq.default" "^tasks\..*$"

	echo "Users created"

	echo "Applying RabbitMQ definitions..."
	rabbitmqctl import_definitions /etc/rabbitmq/definitions.json 2>/dev/null || echo "Definitions already applied"
else
	echo "Users already exist"
fi

echo "RabbitMQ initialization complete"

# Keep process alive to maintain heartbeat
wait
