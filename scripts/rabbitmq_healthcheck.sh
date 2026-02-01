#!/bin/sh
set -e

# Check if the node itself is running
if ! rabbitmq-diagnostics check_running >/dev/null 2>&1; then
  echo "Node not running"
  exit 1
fi

# Node is running - that's healthy
echo "OK - node is running"
exit 0
