package postgres

import (
	"context"
	"time"

	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/domain"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/port"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
)

type taskRepository struct {
	db  *pgxpool.Pool
	log *zap.Logger
}

// NewTaskRepository creates a new postgres repository
func NewTaskRepository(db *pgxpool.Pool, log *zap.Logger) port.TaskRepository {
	return &taskRepository{
		db:  db,
		log: log,
	}
}

func (r *taskRepository) Save(ctx context.Context, task *domain.Task) error {
	query := `
		INSERT INTO tasks (id, name, image, command, priority, required_cpu, required_memory, status, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
	`
	_, err := r.db.Exec(ctx, query,
		task.ID, task.Name, task.Image, task.Command, task.Priority,
		task.RequiredCPU, task.RequiredMemory, task.Status, task.CreatedAt, task.UpdatedAt)

	if err != nil {
		r.log.Error("Failed to save task", zap.Error(err))
		return err
	}
	return nil
}

func (r *taskRepository) GetByID(ctx context.Context, id string) (*domain.Task, error) {
	query := `SELECT id, name, image, status, priority FROM tasks WHERE id = $1`
	row := r.db.QueryRow(ctx, query, id)

	var task domain.Task
	if err := row.Scan(&task.ID, &task.Name, &task.Image, &task.Status, &task.Priority); err != nil {
		return nil, err
	}
	return &task, nil
}

func (r *taskRepository) UpdateStatus(ctx context.Context, id string, status domain.TaskStatus, nodeID string) error {
	query := `UPDATE tasks SET status = $1, assigned_node_id = $2, updated_at = $3 WHERE id = $4`
	_, err := r.db.Exec(ctx, query, status, nodeID, time.Now(), id)
	return err
}

func (r *taskRepository) ListPending(ctx context.Context) ([]*domain.Task, error) {
	query := `SELECT id, name, image, status, priority, required_cpu, required_memory FROM tasks WHERE status = 'PENDING' ORDER BY priority DESC`
	rows, err := r.db.Query(ctx, query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tasks []*domain.Task
	for rows.Next() {
		var t domain.Task
		if err := rows.Scan(&t.ID, &t.Name, &t.Image, &t.Status, &t.Priority, &t.RequiredCPU, &t.RequiredMemory); err != nil {
			return nil, err
		}
		tasks = append(tasks, &t)
	}
	return tasks, nil
}
