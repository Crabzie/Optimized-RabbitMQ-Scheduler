package rabbitmq

import (
	"context"
	"encoding/json"

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
	conn, err := amqp.Dial(url)
	if err != nil {
		return nil, err
	}

	ch, err := conn.Channel()
	if err != nil {
		return nil, err
	}

	return &queueService{
		conn: conn,
		ch:   ch,
		log:  log,
	}, nil
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
