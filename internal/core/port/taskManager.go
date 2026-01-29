// Package port provides behavior interfaces that connects service & storage & handler.
package port

import "context"

// TaskManagerRepository is an interface for interacting with task manager-related data
type TaskManagerRepository interface {
	InsertTask(ctx context.Context, taskManager *domain.TaskManager) (*domain.TaskManager, error)
	GetTaskByID(ctx context.Context, id string) (*domain.TaskManager, error)
	DisableTaskByID(ctx context.Context, id string) error
	RestartTaskByID(ctx context.Context, id string) error
	RemoveTaskByID(ctx context.Context, id string) error
}

// TaskManagerService is an interface for interacting with task manager-related business logic
type TaskManagerService interface {
	InsertTask(ctx context.Context, taskManager *domain.TaskManager) (*domain.TaskManager, error)
	GetTaskByID(ctx context.Context, id string) (*domain.TaskManager, error)
	DisableTaskByID(ctx context.Context, id string) error
	RestartTaskByID(ctx context.Context, id string) error
	RemoveTaskByID(ctx context.Context, id string) error
}
