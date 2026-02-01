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

## 3. Live Logs
To see exactly how tasks are being distributed and processed in real-time, use the aggregated monitoring command.

### Aggregated Node & Scheduler View (Recommended)
This command follows logs from the scheduler and all three fog nodes simultaneously. It's the best way to see the "flow" of tasks.
```bash
make monitor
```

### Infrastructure Logs
To see logs from RabbitMQ, Redis, and Postgres:
```bash
make logs-follow
```

This setup provides a clean, labeled view of the entire scheduling process.
