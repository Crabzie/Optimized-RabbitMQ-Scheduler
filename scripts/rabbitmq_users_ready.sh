#!/bin/sh
set -e

echo "🔍 RabbitMQ users check..."

rabbitmq-diagnostics ping >/dev/null 2>&1 || exit 1

rabbitmqctl list_vhosts | grep -q "^/fog$" || exit 1

rabbitmqctl list_permissions -p /fog | grep -q "scheduler_worker" || exit 1

[ -z "$MQ_WORKER_USER" ] || rabbitmqctl list_permissions -p /fog | grep -q "$MQ_WORKER_USER"

echo "✅ Users ready!"
