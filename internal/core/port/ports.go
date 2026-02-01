package port

import (
	"context"

	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/domain"
)

// TaskRepository defines how tasks are persisted
type TaskRepository interface {
	Save(ctx context.Context, task *domain.Task) error
	GetByID(ctx context.Context, id string) (*domain.Task, error)
	UpdateStatus(ctx context.Context, id string, status domain.TaskStatus, nodeID string) error
	ListPending(ctx context.Context) ([]*domain.Task, error)
}

// NodeCoordinator defines how we track cluster members (Redis)
type NodeCoordinator interface {
	RegisterNode(ctx context.Context, node *domain.Node) error
	GetActiveNodes(ctx context.Context) ([]*domain.Node, error)
}

// QueueService defines how we publish and consume tasks
type QueueService interface {
	PublishTask(ctx context.Context, task *domain.Task) error
	ConsumeTasks(ctx context.Context, handler func(task *domain.Task) error) error
}

// MonitoringService defines how we fetch live metrics (Prometheus)
type MonitoringService interface {
	GetNodeMetrics(ctx context.Context, nodeID string) (float64, float64, error) // Returns CPU, Mem usage
	GetAllNodesMetrics(ctx context.Context) (map[string]domain.NodeMetrics, error)
}
