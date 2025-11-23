#!/usr/bin/env bash
set -euo pipefail

# Check the node itself is running
if ! rabbitmq-diagnostics check_running >/dev/null 2>&1; then
  echo "Node not running"
  exit 1
fi

# Get cluster status and count running nodes
RUNNING_NODES=$(rabbitmqctl cluster_status --formatter json 2>/dev/null | \
  jq -r '.running_nodes | length' 2>/dev/null || echo "0")

# If there are 2+ running nodes, we're clustered → healthy
if [[ "$RUNNING_NODES" -ge 2 ]]; then
  echo "OK - clustered with $RUNNING_NODES nodes"
  exit 0
fi

# If only 1 node (this one), it's standalone -> unhealthy
echo "WARN - not clustered (only $RUNNING_NODES running node)"
exit 1
