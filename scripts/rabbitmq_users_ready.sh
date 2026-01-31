#!/usr/bin/env bash
set -euo pipefail

echo "🔍 RabbitMQ users check..."

rabbitmq-diagnostics ping >/dev/null 2>&1 || exit 1

rabbitmqctl list_vhosts | grep -q "^/fog$" || exit 1

rabbitmqctl list_permissions -p /fog | grep -q "scheduler_worker" || exit 1

[ -z "$MQWORKERUSER" ] || rabbitmqctl list_permissions -p /fog | grep -q "$MQWORKERUSER"

echo "✅ Users ready!"
