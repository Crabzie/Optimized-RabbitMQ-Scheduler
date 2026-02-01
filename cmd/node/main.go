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
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/adapter/queue/rabbitmq"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/adapter/storage/postgres"
	redisAdapter "github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/adapter/storage/redis"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/service"
	redigo "github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

func main() {
	rootCtx, rootCtxCancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer rootCtxCancel()

	// 1. Init Config & Logger
	appConfig := config.New()
	log := logger.Build(appConfig.Logger)
	zap.ReplaceGlobals(log)

	nodeName := os.Getenv("NODE_NAME")
	if nodeName == "" {
		nodeName = fmt.Sprintf("fog-node-%d", time.Now().Unix())
	}
	log = log.With(zap.String("service", "worker"), zap.String("node", nodeName))
	log.Info("Starting Fog Node Worker")

	// 2. Init Adapters

	// Postgres
	dbService, err := postgresConfig.New(rootCtx, appConfig.DB, log)
	if err != nil {
		log.Fatal("Failed to init Postgres", zap.Error(err))
	}
	taskRepo := postgres.NewTaskRepository(dbService.Pool, log)

	// Redis with Retry
	var redisClient *redigo.Client
	maxRedisRetries := 10
	for i := 1; i <= maxRedisRetries; i++ {
		redisClient = redigo.NewClient(&redigo.Options{
			Addr:     appConfig.Redis.Addr,
			Password: appConfig.Redis.Password,
			DB:       0,
		})
		if err := redisClient.Ping(rootCtx).Err(); err == nil {
			break
		} else {
			log.Warn("Failed to connect to Redis, retrying...", zap.Int("attempt", i), zap.Error(err))
			redisClient.Close()
			if i == maxRedisRetries {
				log.Fatal("Failed to init Redis after max retries", zap.Error(err))
			}
			time.Sleep(time.Duration(i*2) * time.Second)
		}
	}
	nodeCoordinator := redisAdapter.NewNodeCoordinator(redisClient, log)

	// RabbitMQ
	rabbitUser := os.Getenv("MQ_WORKER_USER")
	rabbitPass := os.Getenv("MQ_WORKER_PASS")
	rabbitHost := os.Getenv("MQ_HOST")
	rabbitPort := os.Getenv("MQ_PORT")

	if rabbitUser == "" {
		rabbitUser = "guest"
	}
	if rabbitPass == "" {
		rabbitPass = "guest"
	}
	if rabbitHost == "" {
		rabbitHost = "rabbitmq"
	}
	if rabbitPort == "" {
		rabbitPort = "5672"
	}

	rabbitURL := fmt.Sprintf("amqp://%s:%s@%s:%s/fog",
		rabbitUser, rabbitPass,
		rabbitHost, rabbitPort,
	)

	queueService, err := rabbitmq.NewQueueService(rabbitURL, log)
	if err != nil {
		log.Fatal("Failed to init RabbitMQ", zap.Error(err), zap.String("url", rabbitURL))
	}

	// 3. Init Worker Service
	worker := service.NewWorkerService(nodeName, taskRepo, nodeCoordinator, queueService, log)

	// 4. Start Worker
	if err := worker.StartWorker(rootCtx); err != nil {
		log.Fatal("Failed to start worker", zap.Error(err))
	}

	log.Info("Worker started successfully. Waiting for tasks...")

	// 5. Wait for Shutdown
	<-rootCtx.Done()
	log.Info("Shutting down...")

	// Cleanup
	dbService.Close()
	redisClient.Close()

	time.Sleep(1 * time.Second)
	log.Info("Shutdown complete")
}
