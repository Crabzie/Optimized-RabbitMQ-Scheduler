package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/config/logger"
	postgresConfig "github.com/crabzie/Optimized-RabbitMQ-Scheduler/config/storage/postgresql"
	config "github.com/crabzie/Optimized-RabbitMQ-Scheduler/config/utils"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/adapter/monitoring/prometheus"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/adapter/queue/rabbitmq"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/adapter/storage/postgres"
	redisAdapter "github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/adapter/storage/redis"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/service"
	redigo "github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

const (
	_shutdownPeriod = 10 * time.Second
)

func main() {
	rootCtx, rootCtxCancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer rootCtxCancel()

	// 1. Init Config & Logger
	appConfig := config.New()
	log := logger.Build(appConfig.Logger)
	zap.ReplaceGlobals(log)
	log.Info("Starting Scheduler Application")

	// 2. Init Adapters

	// Postgres
	dbService, err := postgresConfig.New(rootCtx, appConfig.DB, log)
	if err != nil {
		log.Fatal("Failed to init Postgres", zap.Error(err))
	}
	// Migrate DB
	if err := dbService.Migrate(); err != nil {
		log.Fatal("Failed to migrate DB", zap.Error(err))
	}
	taskRepo := postgres.NewTaskRepository(dbService.Pool, log)

	// Redis
	redisClient := redigo.NewClient(&redigo.Options{
		Addr:     appConfig.Redis.Addr,
		Password: appConfig.Redis.Password,
		DB:       0,
	})
	if err := redisClient.Ping(rootCtx).Err(); err != nil {
		log.Fatal("Failed to init Redis", zap.Error(err))
	}
	nodeCoordinator := redisAdapter.NewNodeCoordinator(redisClient, log)

	// RabbitMQ
	// Build URL from Env or Config
	rabbitUser := os.Getenv("MQ_ADMIN_USER")
	rabbitPass := os.Getenv("MQ_ADMIN_PASS")
	rabbitHost := os.Getenv("MQ_HOST")
	rabbitPort := os.Getenv("MQ_PORT")

	if rabbitUser == "" {
		rabbitUser = "admin"
	}
	if rabbitPass == "" {
		rabbitPass = "your_admin_password"
	}
	if rabbitHost == "" {
		rabbitHost = "rabbitmq"
	}
	if rabbitPort == "" {
		rabbitPort = "5672"
	}

	rabbitURL := fmt.Sprintf("amqp://%s:%s@%s:%s/",
		rabbitUser, rabbitPass,
		rabbitHost, rabbitPort,
	)

	queueService, err := rabbitmq.NewQueueService(rabbitURL, log)
	if err != nil {
		// Log but maybe not fatal if we want to retry? For now fatal.
		log.Fatal("Failed to init RabbitMQ", zap.Error(err), zap.String("url", rabbitURL))
	}

	// Prometheus
	promURL := "http://prometheus:9090" // Container name
	monitorService := prometheus.NewMonitoringService(promURL, log)

	// 3. Init Service
	scheduler := service.NewSchedulerService(taskRepo, nodeCoordinator, monitorService, queueService, log)

	// 4. Start Loops
	log.Info("Services initialized. Starting Scheduler Loop...")
	go scheduler.StartScheduler(rootCtx, 10*time.Second)

	// 5. Wait for Shutdown
	<-rootCtx.Done()
	log.Info("Shutting down...")

	// Cleanup
	dbService.Close()
	redisClient.Close()

	// Wait for grace period
	time.Sleep(1 * time.Second)
	log.Info("Shutdown complete")
}
