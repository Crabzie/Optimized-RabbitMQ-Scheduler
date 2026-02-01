# Demonstration Guide: Intelligent RabbitMQ Scheduler

This guide explains how to showcase the core features of your scheduler to your professor.

## 1. Automated Traffic Simulation
The best way to show the logic "in action" is to run the simulation script. It injects a variety of tasks (High/Low priority, Heavy/Lite resource needs) and monitors the scheduler's decisions.

**Command:**
```bash
make test-simulation
```

**What to point out to the professor:**
- **Priority Handling**: Watch how high-priority tasks are picked up first.
- **Resource Awareness**: Notice how the scheduler assigns "Heavy" tasks to nodes with available capacity (CPU/RAM).
- **Real-time Logs**: The terminal will show: `Scheduler assigned task-X -> fog-node-Y`.

---

## 2. Visual Monitoring
Show the "Nerve Center" of your system.

### A. RabbitMQ Management UI
**URL:** [http://localhost:15672](http://localhost:15672) (User: `scheduler_admin`, Pass: `SecureAdminPass!`)
- **Queues**: Show the three priority queues. You can see the message counts fluctuating as tasks are processed.
- **Connections**: Show the 3 different `fog-nodes` and the `scheduler` connected to the `/fog` vhost.

### B. Grafana Dashboard
**URL:** [http://localhost:3000](http://localhost:3000) (User: `admin`, Pass: `SecureGrafana2025!`)
- Navigate to the **"Node Resources"** dashboard.
- **What to show**: The live graphs of CPU and Memory usage for each fog node. Explain that the scheduler uses this real-time Prometheus data to make "Intelligent" placement decisions.

---

## 3. High Availability & Failover (Advanced Demo)
This is usually what impresses professors the most—resilience.

1. Start the simulation (`make test-simulation`).
2. While it's running, **force-kill one of the nodes**:
   ```bash
   docker service scale fog-scheduler_fog-node-1=0
   ```
3. **Observation**:
   - The scheduler will detect the node is down (via the Redis coordinator).
   - Tasks will be re-routed to `fog-node-2` and `fog-node-3`.
   - The Grafana dashboard will show the node disappearing, and others taking more load.
4. **Recovery**: Bring it back:
   ```bash
   docker service scale fog-scheduler_fog-node-1=1
   ```
   Show how it re-registers and starts taking tasks again.

---

## 4. Technical deep-dive
If asked about the code structure, you can highlight:
- **Clean Architecture**: Domain, Ports, and Adapters (Postgres, RabbitMQ, Redis).
- **Concurrency**: Go routines handling Heartbeats and Task Processing in parallel.
- **Resilience**: The retry logic we just implemented to handle network/DNS issues.
