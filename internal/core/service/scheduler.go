package service

import (
	"context"
	"sort"
	"time"

	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/domain"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/port"
	"go.uber.org/zap"
)

type schedulerService struct {
	taskRepo    port.TaskRepository
	coordinator port.NodeCoordinator
	monitor     port.MonitoringService
	queue       port.QueueService
	log         *zap.Logger
}

func NewSchedulerService(
	taskRepo port.TaskRepository,
	coordinator port.NodeCoordinator,
	monitor port.MonitoringService,
	queue port.QueueService,
	log *zap.Logger,
) *schedulerService {
	return &schedulerService{
		taskRepo:    taskRepo,
		coordinator: coordinator,
		monitor:     monitor,
		queue:       queue,
		log:         log,
	}
}

// StartScheduler starts the polling loop
func (s *schedulerService) StartScheduler(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	count := 0
	for {
		select {
		case <-ctx.Done():
			s.log.Info("Stopping scheduler loop")
			return
		case <-ticker.C:
			count++
			if count%3 == 0 {
				nodes, _ := s.coordinator.GetActiveNodes(ctx)
				s.log.Info("Scheduler Heartbeat - Active and Monitoring",
					zap.Int("active_nodes", len(nodes)),
					zap.Duration("interval", interval))
			}

			if err := s.SchedulePendingTasks(ctx); err != nil {
				s.log.Error("Failed to schedule tasks", zap.Error(err))
			}
		}
	}
}

func (s *schedulerService) SchedulePendingTasks(ctx context.Context) error {
	// 1. Fetch pending tasks
	tasks, err := s.taskRepo.ListPending(ctx)
	if err != nil {
		return err
	}
	if len(tasks) == 0 {
		return nil
	}

	s.log.Info("Scheduler found pending tasks", zap.Int("count", len(tasks)))

	// 2. Get Active Nodes
	nodes, err := s.coordinator.GetActiveNodes(ctx)
	if err != nil {
		return err
	}
	if len(nodes) == 0 {
		s.log.Warn("No active nodes available to schedule tasks")
		return nil
	}

	// 3. Optimized Metrics Fetching: Get all node metrics once per cycle
	metricsMap, err := s.monitor.GetAllNodesMetrics(ctx)
	if err != nil {
		s.log.Warn("Failed to fetch batch metrics, will use individual fallback in SelectBestNode", zap.Error(err))
	}

	// 4. Process each task
	for _, task := range tasks {
		bestNode, err := s.SelectBestNode(ctx, task, nodes, metricsMap)
		if err != nil {
			s.log.Warn("Could not find suitable node for task", zap.String("task_id", task.ID), zap.Error(err))
			continue
		}

		// 5. Assign and Publish
		task.AssignedNodeID = bestNode.ID
		task.Status = domain.TaskStatusScheduled

		// Update DB first
		if err := s.taskRepo.UpdateStatus(ctx, task.ID, domain.TaskStatusScheduled, bestNode.ID); err != nil {
			s.log.Error("Failed to update task status", zap.Error(err))
			continue
		}

		// Publish to Queue
		if err := s.queue.PublishTask(ctx, task); err != nil {
			s.log.Error("Failed to publish task", zap.Error(err))
			continue
		}

		s.log.Info("Successfully scheduled task",
			zap.String("task_id", task.ID),
			zap.String("node_id", bestNode.ID),
			zap.Float64("node_cpu_free", bestNode.AvailableCPU()))
	}

	return nil
}

func (s *schedulerService) SelectBestNode(ctx context.Context, task *domain.Task, nodes []*domain.Node, metrics map[string]domain.NodeMetrics) (*domain.Node, error) {
	type nodeScore struct {
		Node  *domain.Node
		Score float64
	}

	var candidates []nodeScore

	for _, node := range nodes {
		var cpuUsage, memUsage float64
		// Check if we have batch metrics for this node
		if m, ok := metrics[node.ID]; ok {
			cpuUsage = m.CPUUsage
			memUsage = m.MemUsage
		} else {
			// Fallback to individual fetch
			var err error
			cpuUsage, memUsage, err = s.monitor.GetNodeMetrics(ctx, node.ID)
			if err != nil {
				s.log.Warn("Failed to get metrics for node, skipping", zap.String("node_id", node.ID), zap.Error(err))
				continue
			}
		}

		s.log.Debug("Evaluated node capacity",
			zap.String("node_id", node.ID),
			zap.Float64("used_cpu", cpuUsage),
			zap.Float64("used_mem", memUsage))

		node.UsedCPU = cpuUsage
		node.UsedMemory = memUsage

		// Check Constraints
		if node.AvailableCPU() < task.RequiredCPU {
			continue
		}
		if node.AvailableMemory() < task.RequiredMemory {
			continue
		}

		// Calculate Score
		// Higher is better.
		// Score = (FreeCPU / taskReqCPU) + (FreeMem / taskReqMem)
		// This favors nodes with MORE headroom relative to the task
		// Avoiding division by zero
		cpuScore := 0.0
		if task.RequiredCPU > 0 {
			cpuScore = node.AvailableCPU() / task.RequiredCPU
		} else {
			cpuScore = node.AvailableCPU() // Just use raw available
		}

		memScore := 0.0
		if task.RequiredMemory > 0 {
			memScore = node.AvailableMemory() / task.RequiredMemory
		} else {
			memScore = node.AvailableMemory() / 100 // Normalize
		}

		// Weighted Score
		totalScore := (cpuScore * 0.6) + (memScore * 0.4) // Favor CPU slightly?

		candidates = append(candidates, nodeScore{Node: node, Score: totalScore})
	}

	if len(candidates) == 0 {
		return nil, context.DeadlineExceeded // Or custom error "No node found"
	}

	// Sort Descending
	sort.Slice(candidates, func(i, j int) bool {
		return candidates[i].Score > candidates[j].Score
	})

	return candidates[0].Node, nil
}
