package rabbitmq

import (
	"context"
	"encoding/json"

	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/domain"
	"go.uber.org/zap"
)

// ConsumeTasks listens to tasks.direct queue (or specific worker queue)
func (q *queueService) ConsumeTasks(ctx context.Context, handler func(task *domain.Task) error) error {
	// 1. Declare Queue ensure it exists
	// We consume from "tasks.normal" for simplicity in this prototype.
	// Real world: workers might listen to "tasks.high" and "tasks.normal" with different consumers.
	qName := "tasks.normal"

	_, err := q.ch.QueueDeclare(
		qName, // name
		true,  // durable (matches definitions.json usually)
		false, // delete when unused
		false, // exclusive
		false, // no-wait
		nil,   // arguments
	)
	if err != nil {
		return err
	}

	msgs, err := q.ch.Consume(
		qName, // queue
		"",    // consumer
		false, // auto-ack (We want to ack manually after work is done)
		false, // exclusive
		false, // no-local
		false, // no-wait
		nil,   // args
	)
	if err != nil {
		return err
	}

	q.log.Info("Started consuming tasks", zap.String("queue", qName))

	go func() {
		for d := range msgs {
			var task domain.Task
			if err := json.Unmarshal(d.Body, &task); err != nil {
				q.log.Error("Failed to unmarshal task", zap.Error(err))
				d.Nack(false, false) // discard invalid message
				continue
			}

			q.log.Info("Received task", zap.String("id", task.ID))

			// Execute Handler
			if err := handler(&task); err != nil {
				q.log.Error("Task handling failed", zap.Error(err))
				// Retry? dead letter? For now, we Nack requeue if transient, or Nack no-requeue if fatal.
				// Let's assume re-queue for robustness
				d.Nack(false, true)
			} else {
				d.Ack(false)
				q.log.Info("Task processed successfully", zap.String("id", task.ID))
			}
		}
	}()

	return nil
}
