package service

import (
	"context"
	"fmt"
	"os"
	"time"

	"net/http"

	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/domain"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/port"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.uber.org/zap"
)

type workerService struct {
	nodeID      string
	taskRepo    port.TaskRepository
	coordinator port.NodeCoordinator
	queue       port.QueueService
	log         *zap.Logger

	// Metrics
	cpuGauge *prometheus.GaugeVec
	memGauge *prometheus.GaugeVec
}

func NewWorkerService(
	nodeID string,
	taskRepo port.TaskRepository,
	coordinator port.NodeCoordinator,
	queue port.QueueService,
	log *zap.Logger,
) *workerService {
	// Register Prometheus Metrics
	cpuGauge := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "node_cpu_seconds_total", // Matching the query the scheduler uses
		Help: "Current CPU usage percentage (simulated)",
	}, []string{"instance", "mode"}) // instance label matches scheduler query

	memGauge := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "node_memory_MemTotal_bytes",
		Help: "Total memory available (simulated)",
	}, []string{"instance"})

	prometheus.MustRegister(cpuGauge)
	prometheus.MustRegister(memGauge)

	return &workerService{
		nodeID:      nodeID,
		taskRepo:    taskRepo,
		coordinator: coordinator,
		queue:       queue,
		log:         log,
		cpuGauge:    cpuGauge,
		memGauge:    memGauge,
	}
}

// StartWorker initializes the worker: starts heartbeat and task consumer
func (w *workerService) StartWorker(ctx context.Context) error {
	w.log.Info("Starting Worker Node", zap.String("id", w.nodeID))

	// 1. Start Metrics Server
	go w.startMetricsServer()

	// 2. Start Heartbeat Loop (Background)
	go w.heartbeatLoop(ctx)

	// 3. Start Consumer
	// The handler function defines what we do when we get a task
	err := w.queue.ConsumeTasks(ctx, w.processTask)
	if err != nil {
		return fmt.Errorf("failed to start consumer: %w", err)
	}

	return nil
}

func (w *workerService) heartbeatLoop(ctx context.Context) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Update metrics for Prometheus to scrape
			// In a real system, we'd gather actual system metrics.
			// For this prototype, we'll simulate some realistic numbers.
			w.cpuGauge.WithLabelValues(w.nodeID, "idle").Set(95.0) // 95% idle = 5% usage
			w.memGauge.WithLabelValues(w.nodeID).Set(4096 * 1024 * 1024)

			node := &domain.Node{
				ID:            w.nodeID,
				Hostname:      os.Getenv("HOSTNAME"),
				Status:        domain.NodeStatusActive,
				LastHeartbeat: time.Now(),
				// Static capacity (example) - could be injected via config
				TotalCPU:    2.0,
				TotalMemory: 4096,
			}

			if err := w.coordinator.RegisterNode(ctx, node); err != nil {
				w.log.Error("Heartbeat failed", zap.Error(err))
			} else {
				w.log.Info("Heartbeat sent - Node registered as active")
			}
		}
	}
}

func (w *workerService) processTask(task *domain.Task) error {
	w.log.Info("Processing Task...", zap.String("id", task.ID), zap.String("cmd", fmt.Sprintf("%v", task.Command)))

	// 1. Update Status to RUNNING
	ctx := context.Background() // New context for DB op
	if err := w.taskRepo.UpdateStatus(ctx, task.ID, domain.TaskStatusRunning, w.nodeID); err != nil {
		w.log.Error("Failed to update status to RUNNING", zap.Error(err))
		return err
	}

	// 2. Simulate Execution (The Work)
	// Here we would actually run the container using Docker SDK or similar.
	// For this prototype, we simulate work with Sleep.
	time.Sleep(5 * time.Second)

	// 3. Update Status to COMPLETED
	if err := w.taskRepo.UpdateStatus(ctx, task.ID, domain.TaskStatusCompleted, w.nodeID); err != nil {
		w.log.Error("Failed to update status to COMPLETED", zap.Error(err))
		return err
	}

	w.log.Info("Task Completed", zap.String("id", task.ID))
	return nil
}

func (w *workerService) startMetricsServer() {
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())

	srv := &http.Server{
		Addr:    ":2112",
		Handler: mux,
	}

	w.log.Info("Starting metrics server on :2112")
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		w.log.Error("Metrics server failed", zap.Error(err))
	}
}
