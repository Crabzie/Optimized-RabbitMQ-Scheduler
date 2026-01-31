#!/usr/bin/env bash
set -euo pipefail

# Check if the node itself is running
if ! rabbitmq-diagnostics check_running >/dev/null 2>&1; then
  echo "Node not running"
  exit 1
fi

# Check if initialization is complete
if [ ! -f /var/lib/rabbitmq/.init_complete ]; then
  echo "Initialization not complete"
  exit 1
fi

# Node is running - that's healthy
echo "OK - node is running and initialized"
exit 0
