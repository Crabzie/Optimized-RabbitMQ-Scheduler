#!/bin/bash
set -euo pipefail

# Configuration
NODE_ID="${HOSTNAME}"
REDIS_HOST="${REDIS_HOST}"
REDIS_PORT="${REDIS_PORT}"
REDIS_PASS="${REDIS_PASS}"
HEARTBEAT_INTERVAL=30
METRICS_KEY_PREFIX="node:${NODE_ID}"

REDIS_CMD="redis-cli -h $REDIS_HOST -p $REDIS_PORT -a $REDIS_PASS --no-auth-warning"

if ! command -v bc &> /dev/null; then
    echo "Installing bc for calculations..."
    apk add --no-cache bc > /dev/null 2>&1 || true
fi
