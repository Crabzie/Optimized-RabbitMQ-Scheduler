#!/bin/sh
set -e

echo "Waiting for RabbitMQ App to be ready..."
# We wait for the local rabbitmq app to be running so we can use rabbitmqctl
until rabbitmqctl status >/dev/null 2>&1; do
  sleep 2
done

echo "RabbitMQ is up. Initializing configuration..."

# 1. CREATE /fog VHOST (Idempotent)
echo "Creating /fog vhost..."
rabbitmqctl add_vhost /fog 2>/dev/null || true

# 2. IMPORT DEFINITIONS (Queues, Exchanges)
echo "Importing RabbitMQ definitions..."
if [ -f /etc/rabbitmq/definitions.json ]; then
    rabbitmqctl import_definitions /etc/rabbitmq/definitions.json 2>/dev/null || true
    echo "Definitions imported."
else
    echo "Warning: definitions.json not found!"
fi

# 3. USER MANAGEMENT
echo "Configuring users..."

# Create Admin
rabbitmqctl add_user "${MQ_ADMIN_USER}" "${MQ_ADMIN_PASS}" 2>/dev/null || true
rabbitmqctl set_user_tags "${MQ_ADMIN_USER}" administrator

# Create Worker User (from env)
rabbitmqctl add_user "${MQ_WORKER_USER}" "${MQ_WORKER_PASS}" 2>/dev/null || true
rabbitmqctl set_user_tags "${MQ_WORKER_USER}" worker

# Create Hardcoded scheduler_worker (if used by legacy code)
rabbitmqctl add_user scheduler_worker SecureWorkerPass! 2>/dev/null || true
rabbitmqctl set_user_tags scheduler_worker worker

# 4. PERMISSIONS (Always Apply)
echo "Setting permissions..."

# Admin gets everything
rabbitmqctl set_permissions -p /fog "${MQ_ADMIN_USER}" ".*" ".*" ".*"

# Workers get access to tasks and default exchange
# Note: Using ".*" ".*" ".*" for workers temporarily to eliminate permission issues during debugging
rabbitmqctl set_permissions -p /fog "${MQ_WORKER_USER}" ".*" ".*" ".*"
rabbitmqctl set_permissions -p /fog scheduler_worker ".*" ".*" ".*"

echo "RabbitMQ initialization complete."
