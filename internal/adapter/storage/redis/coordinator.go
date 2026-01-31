package redis

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/domain"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/port"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

type nodeCoordinator struct {
	client *redis.Client
	log    *zap.Logger
}

func NewNodeCoordinator(client *redis.Client, log *zap.Logger) port.NodeCoordinator {
	return &nodeCoordinator{
		client: client,
		log:    log,
	}
}

// RegisterNode saves the node state for 30 seconds (Heartbeat)
func (c *nodeCoordinator) RegisterNode(ctx context.Context, node *domain.Node) error {
	data, err := json.Marshal(node)
	if err != nil {
		return err
	}

	key := fmt.Sprintf("node:%s", node.ID)
	return c.client.Set(ctx, key, data, 30*time.Second).Err()
}

func (c *nodeCoordinator) GetActiveNodes(ctx context.Context) ([]*domain.Node, error) {
	keys, err := c.client.Keys(ctx, "node:*").Result()
	if err != nil {
		return nil, err
	}

	var nodes []*domain.Node
	for _, key := range keys {
		val, err := c.client.Get(ctx, key).Result()
		if err != nil {
			continue
		}

		var node domain.Node
		if err := json.Unmarshal([]byte(val), &node); err == nil {
			nodes = append(nodes, &node)
		}
	}
	return nodes, nil
}
