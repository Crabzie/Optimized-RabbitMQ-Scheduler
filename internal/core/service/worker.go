package service

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/domain"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/port"
	"go.uber.org/zap"
)

type workerService struct {
	nodeID      string
	taskRepo    port.TaskRepository
	coordinator port.NodeCoordinator
	queue       port.QueueService
	log         *zap.Logger
}

func NewWorkerService(
	nodeID string,
	taskRepo port.TaskRepository,
	coordinator port.NodeCoordinator,
	queue port.QueueService,
	log *zap.Logger,
) *workerService {
	return &workerService{
		nodeID:      nodeID,
		taskRepo:    taskRepo,
		coordinator: coordinator,
		queue:       queue,
		log:         log,
	}
}

// StartWorker initializes the worker: starts heartbeat and task consumer
func (w *workerService) StartWorker(ctx context.Context) error {
	w.log.Info("Starting Worker Node", zap.String("id", w.nodeID))

	// 1. Start Heartbeat Loop (Background)
	go w.heartbeatLoop(ctx)

	// 2. Start Consumer
	// The handler function defines what we do when we get a task
	err := w.queue.ConsumeTasks(ctx, w.processTask)
	if err != nil {
		return fmt.Errorf("failed to start consumer: %w", err)
	}

	return nil
}

func (w *workerService) heartbeatLoop(ctx context.Context) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Ping Redis to say "I'm alive"
			// In a real system, we'd gather actual CPU/Mem here if pushing.
			// Since we use Prometheus pull, this is mostly for "Active Nodes" list discovery.
			node := &domain.Node{
				ID:            w.nodeID,
				Hostname:      os.Getenv("HOSTNAME"),
				Status:        domain.NodeStatusActive,
				LastHeartbeat: time.Now(),
				// Static capacity (example) - could be injected via config
				TotalCPU:    2.0,
				TotalMemory: 4096,
			}

			if err := w.coordinator.RegisterNode(ctx, node); err != nil {
				w.log.Error("Heartbeat failed", zap.Error(err))
			} else {
				w.log.Debug("Heartbeat sent")
			}
		}
	}
}

func (w *workerService) processTask(task *domain.Task) error {
	w.log.Info("Processing Task...", zap.String("id", task.ID), zap.String("cmd", fmt.Sprintf("%v", task.Command)))

	// 1. Update Status to RUNNING
	ctx := context.Background() // New context for DB op
	if err := w.taskRepo.UpdateStatus(ctx, task.ID, domain.TaskStatusRunning, w.nodeID); err != nil {
		w.log.Error("Failed to update status to RUNNING", zap.Error(err))
		return err
	}

	// 2. Simulate Execution (The Work)
	// Here we would actually run the container using Docker SDK or similar.
	// For this prototype, we simulate work with Sleep.
	time.Sleep(5 * time.Second)

	// 3. Update Status to COMPLETED
	if err := w.taskRepo.UpdateStatus(ctx, task.ID, domain.TaskStatusCompleted, w.nodeID); err != nil {
		w.log.Error("Failed to update status to COMPLETED", zap.Error(err))
		return err
	}

	w.log.Info("Task Completed", zap.String("id", task.ID))
	return nil
}
