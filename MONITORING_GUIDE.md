# Dashboard & Monitoring Guide

This guide explains how to use the monitoring tools included in the Optimized RabbitMQ Scheduler.

## 1. RabbitMQ Management Console
**URL**: [http://localhost:15672](http://localhost:15672)
**Credentials**: See `.env` (`MQ_ADMIN_USER`, `MQ_ADMIN_PASS`)

### What to Look For:
- **Exchanges**: Look at `tasks.direct`. You will see traffic spikes here when the scheduler publishes tasks.
- **Queues**: 
    - `tasks.normal`: This is where most tasks will land.
    - `tasks.high_priority` & `tasks.low_priority`: Used for different priority levels.
- **Consumers**: You should see 3 consumers on the `tasks.normal` queue (representing your 3 fog nodes).
- **Message Rates**: The "Publish" rate shows tasks coming from the scheduler. The "Deliver" rate shows tasks being picked up by nodes.

## 2. Grafana Dashboards
**URL**: [http://localhost:3000](http://localhost:3000)
**Credentials**: `admin` / See `.env` (`GRAFANA_PASS`)

### What to Look For:
- **Node Resources**: You will see the simulated CPU and Memory usage for `fog-node-1`, `fog-node-2`, and `fog-node-3`.
- **Scheduler Insight**: The scheduler uses these metrics to decide which node is "least busy" when assigning a task.
- **RabbitMQ Overview**: Metrics about message rates and queue lengths are also available.

## 3. High Debugging Logs
With the latest changes, you can now follow the complete lifecycle of a task in the logs:

1. **Scheduler**: `Scheduler found pending tasks` -> `Successfully scheduled task (task_id -> node_id)`
2. **Database (Repository)**: `Task status updated in DB (status: SCHEDULED)`
3. **Worker (Fog Node)**: `Worker received task from queue` -> `Task status updated in DB (status: RUNNING)`
4. **Worker (Fog Node)**: `Task finished successfully` -> `Task status updated in DB (status: COMPLETED)`

### How to watch:
```bash
make logs-follow
```

## 4. Node Activity Monitor (New!)
For a much cleaner view of what the fog nodes are doing, use the dedicated monitor tool.

### How to watch:
1. Open a new terminal.
2. Run:
```bash
make monitor-nodes
```

### What you will see:
- `[NODE-1] 📥 Received Task: task-123`
- `[NODE-1] ⚙️  Now Running:  task-123`
- `[NODE-1] ✅ Task Finished: task-123`

This tool filters out the noise and highlights exactly when tasks arrive and complete.
