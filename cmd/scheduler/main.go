package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/config/logger"
	postgres "github.com/crabzie/Optimized-RabbitMQ-Scheduler/config/storage/postgresql"
	redis "github.com/crabzie/Optimized-RabbitMQ-Scheduler/config/storage/redis"
	config "github.com/crabzie/Optimized-RabbitMQ-Scheduler/config/utils"
	"go.uber.org/zap"
)

// _shutdownPeriod is time to wait before gracefully shutting server
// _shutdownHardPeriod is time to wait beofre force closing server
// _readinessDrainDelay is time to sleep while context shutdown message propagate
const (
	_shutdownPeriod      = 10 * time.Second
	_shutdownHardPeriod  = 3 * time.Second
	_readinessDrainDelay = 5 * time.Second
)

func main() {
	rootCtx, rootCtxCancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer rootCtxCancel()

	// Init config
	appConfig := config.New()
	baseLogger := logger.Build(appConfig.Logger)
	zap.L().Debug("Logger Builded successfully")

	zap.L().Info("Starting the application", zap.String("app", appConfig.App.Name), zap.String("env", appConfig.App.Env), zap.String("owner", appConfig.App.Owner))

	// Init database service
	dbLogger := baseLogger.Named("DB")
	dbService, err := postgres.New(rootCtx, appConfig.DB, dbLogger)
	if err != nil {
		zap.L().Error("Error initializing database connection", zap.Error(err))
		os.Exit(1)
	}
	zap.L().Info("Successfully connected to the database", zap.String("db", appConfig.DB.Connection))

	// Migrate database
	if err := dbService.Migrate(); err != nil {
		zap.L().Error("Error migrating database", zap.Error(err))
		os.Exit(1)
	}
	zap.L().Info("Successfully migrated the database")

	// Init cache service
	_, err = redis.New(rootCtx, appConfig.Redis)
	if err != nil {
		zap.L().Error("Error initializing cache connection", zap.Error(err))
		os.Exit(1)
	}
	zap.L().Info("Successfully connected to the cache server", zap.String("address", appConfig.Redis.Addr))

	_ = baseLogger.Named("Fiber")

	// Wait for ctx cancelation
	<-rootCtx.Done()
	rootCtxCancel()

	// Wait for signal propagation
	time.Sleep(_readinessDrainDelay)
	zap.L().Info("Readiness check propagated, now waiting for ongoing requests to finish")

	zap.L().Info("Graceful shutdown complete.")
}
