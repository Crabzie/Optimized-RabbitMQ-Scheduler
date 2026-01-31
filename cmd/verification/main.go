package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/config/logger"
	postgresConfig "github.com/crabzie/Optimized-RabbitMQ-Scheduler/config/storage/postgresql"
	config "github.com/crabzie/Optimized-RabbitMQ-Scheduler/config/utils"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/adapter/monitoring/prometheus"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/adapter/queue/rabbitmq"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/adapter/storage/postgres"
	redisAdapter "github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/adapter/storage/redis"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/domain"
	redigo "github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

func main() {
	// 1. Setup Logger & Config
	appConfig := config.New()
	log := logger.Build(appConfig.Logger)
	ctx := context.Background()

	log.Info("Starting Verification...")

	// 2. Test Postgres
	log.Info("--- Testing Postgres ---")
	dbService, err := postgresConfig.New(ctx, appConfig.DB, log)
	if err != nil {
		log.Fatal("Failed to connect to DB", zap.Error(err))
	}
	// Note: dbService matches *postgres.DB which embeds *pgxpool.Pool
	repo := postgres.NewTaskRepository(dbService.Pool, log)

	// Create a dummy task
	task := &domain.Task{
		ID:        fmt.Sprintf("test-task-%d", time.Now().Unix()),
		Name:      "Verification Task",
		Status:    domain.TaskStatusPending,
		Priority:  5,
		CreatedAt: time.Now(),
		UpdatedAt: time.Now(),
	}

	if err := repo.Save(ctx, task); err != nil {
		log.Error("X Postgres: Save Task Failed", zap.Error(err))
	} else {
		log.Info("✓ Postgres: Save Task Success")
	}

	if fetched, err := repo.GetByID(ctx, task.ID); err != nil {
		// Log error but check if it's just zero value or actual error
		log.Error("X Postgres: Get Task Failed", zap.Error(err))
	} else {
		log.Info("✓ Postgres: Get Task Success", zap.String("FetchedID", fetched.ID))
	}

	// 3. Test Redis
	log.Info("--- Testing Redis ---")
	// Creating client directly since the config wrapper returns a fiber storage interface
	redisClient := redigo.NewClient(&redigo.Options{
		Addr:     appConfig.Redis.Addr,
		Password: appConfig.Redis.Password,
		DB:       0,
	})

	if err := redisClient.Ping(ctx).Err(); err != nil {
		log.Fatal("Failed to connect to Redis", zap.Error(err))
	}

	coordinator := redisAdapter.NewNodeCoordinator(redisClient, log)

	node := &domain.Node{
		ID:       "test-node-1",
		Status:   domain.NodeStatusActive,
		TotalCPU: 4,
		UsedCPU:  1,
	}

	if err := coordinator.RegisterNode(ctx, node); err != nil {
		log.Error("X Redis: Register Node Failed", zap.Error(err))
	} else {
		log.Info("✓ Redis: Register Node Success")
	}

	nodes, err := coordinator.GetActiveNodes(ctx)
	if err != nil {
		log.Error("X Redis: Get Nodes Failed", zap.Error(err))
	} else {
		log.Info("✓ Redis: Get Nodes Success", zap.Int("Count", len(nodes)))
	}

	// 4. Test RabbitMQ
	log.Info("--- Testing RabbitMQ ---")
	// Use Env variables or defaults
	user := os.Getenv("MQ_ADMIN_USER")
	if user == "" {
		user = "admin"
	}
	pass := os.Getenv("MQ_ADMIN_PASS")
	if pass == "" {
		pass = "admin"
	}
	host := "localhost"
	port := "5672" // Default port for non-cluster testing or 5672 if mapped

	amqpURL := fmt.Sprintf("amqp://%s:%s@%s:%s/", user, pass, host, port)

	queue, err := rabbitmq.NewQueueService(amqpURL, log)
	if err != nil {
		log.Error("X RabbitMQ: Connection Failed", zap.Error(err))
	} else {
		if err := queue.PublishTask(ctx, task); err != nil {
			log.Error("X RabbitMQ: Publish Failed", zap.Error(err))
		} else {
			log.Info("✓ RabbitMQ: Publish Success")
		}
	}

	// 5. Test Prometheus
	log.Info("--- Testing Prometheus ---")
	promClient := prometheus.NewMonitoringService("http://localhost:9090", log)
	cpu, mem, err := promClient.GetNodeMetrics(ctx, "test-node-1")
	if err != nil {
		log.Warn("! Prometheus: Query Failed (Expected if bad connection or no data)", zap.Error(err))
	} else {
		log.Info("✓ Prometheus: Query Success", zap.Float64("CPU", cpu), zap.Float64("Mem", mem))
	}

	log.Info("Verification Complete.")
}
