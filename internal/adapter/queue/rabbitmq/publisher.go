package rabbitmq

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/domain"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/port"
	amqp "github.com/rabbitmq/amqp091-go"
	"go.uber.org/zap"
)

type queueService struct {
	conn *amqp.Connection
	ch   *amqp.Channel
	log  *zap.Logger
}

func NewQueueService(url string, log *zap.Logger) (port.QueueService, error) {
	var conn *amqp.Connection
	var err error

	// Retry connection up to 10 times with backoff
	maxRetries := 10
	for i := 1; i <= maxRetries; i++ {
		conn, err = amqp.Dial(url)
		if err == nil {
			ch, err := conn.Channel()
			if err == nil {
				return &queueService{
					conn: conn,
					ch:   ch,
					log:  log,
				}, nil
			}
			conn.Close()
		}

		log.Warn("Failed to connect to RabbitMQ, retrying...",
			zap.Int("attempt", i),
			zap.Int("max_retries", maxRetries),
			zap.Error(err),
		)

		// Simple incremental backoff
		time.Sleep(time.Duration(i*2) * time.Second)
	}

	return nil, fmt.Errorf("failed to connect to RabbitMQ after %d attempts: %w", maxRetries, err)
}

func (q *queueService) PublishTask(ctx context.Context, task *domain.Task) error {
	body, err := json.Marshal(task)
	if err != nil {
		return err
	}

	// We publish to the "tasks.direct" exchange
	// Routing key is "task.high" (example, logic should be dynamic based on priority)
	routingKey := "task.normal"
	if task.Priority > 7 {
		routingKey = "task.high"
	} else if task.Priority < 4 {
		routingKey = "task.low"
	}

	err = q.ch.PublishWithContext(ctx,
		"tasks.direct", // Exchange
		routingKey,     // Routing key
		false,          // Mandatory
		false,          // Immediate
		amqp.Publishing{
			ContentType: "application/json",
			Body:        body,
			Priority:    uint8(task.Priority), // RabbitMQ Priority
		})

	if err != nil {
		q.log.Error("Failed to publish task", zap.Error(err))
		return err
	}

	q.log.Info("Published task to RabbitMQ", zap.String("id", task.ID), zap.String("key", routingKey))
	return nil
}
