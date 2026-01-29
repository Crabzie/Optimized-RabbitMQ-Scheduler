// Package redis provides Redis cache server implimentation logic.
package redis

import (
	"context"
	"time"

	config "github.com/crabzie/Optimized-RabbitMQ-Scheduler/config/utils"

	"github.com/gofiber/storage/redis/v3"
	redigo "github.com/redis/go-redis/v9"
)

type Redis struct {
	Client *redis.Storage
}

// New creates a new instance of Redis
func New(ctx context.Context, config *config.Redis) (*Redis, error) {
	client := redigo.NewUniversalClient(&redigo.UniversalOptions{
		Addrs:           []string{config.Addr},
		Password:        config.Password,
		DB:              0,
		MaxRetries:      3,
		MinRetryBackoff: 100 * time.Millisecond,
		MaxRetryBackoff: 1 * time.Second,
		DialTimeout:     5 * time.Second,
		ReadTimeout:     3 * time.Second,
		WriteTimeout:    3 * time.Second,
		PoolSize:        10,
		MinIdleConns:    2,
		ConnMaxIdleTime: 5 * time.Minute,
		// TLSConfig:       &tls.Config{MinVersion: tls.VersionTLS13},
	})

	if _, err := client.Ping(ctx).Result(); err != nil {
		return nil, err
	}

	storage := redis.NewFromConnection(client)

	return &Redis{storage}, nil
}
