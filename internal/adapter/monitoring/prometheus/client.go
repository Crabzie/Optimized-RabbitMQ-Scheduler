package prometheus

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/port"
	"go.uber.org/zap"
)

type monitoringService struct {
	prometheusURL string
	client        *http.Client
	log           *zap.Logger
}

func NewMonitoringService(url string, log *zap.Logger) port.MonitoringService {
	return &monitoringService{
		prometheusURL: url,
		client:        &http.Client{Timeout: 5 * time.Second},
		log:           log,
	}
}

// PrometheusResponse structure for parsing query results
type prometheusResponse struct {
	Status string `json:"status"`
	Data   struct {
		ResultType string `json:"resultType"`
		Result     []struct {
			Metric map[string]string `json:"metric"`
			Value  []interface{}     `json:"value"` // [timestamp, "value"]
		} `json:"result"`
	} `json:"data"`
}

func (s *monitoringService) GetNodeMetrics(ctx context.Context, nodeID string) (float64, float64, error) {
	// Query CPU Usage
	cpuQuery := fmt.Sprintf("100 - (avg by (instance) (rate(node_cpu_seconds_total{mode='idle', instance='%s'}[1m])) * 100)", nodeID)
	cpuUsage, err := s.queryPrometheus(cpuQuery)
	if err != nil {
		return 0, 0, err
	}

	// Query Memory Usage (bytes)
	memQuery := fmt.Sprintf("node_memory_MemTotal_bytes{instance='%s'} - node_memory_MemAvailable_bytes{instance='%s'}", nodeID, nodeID)
	memUsage, err := s.queryPrometheus(memQuery)
	if err != nil {
		return 0, 0, err
	}

	return cpuUsage, memUsage / 1024 / 1024, nil // Convert Bytes to MB
}

func (s *monitoringService) queryPrometheus(query string) (float64, error) {
	url := fmt.Sprintf("%s/api/v1/query?query=%s", s.prometheusURL, query)
	resp, err := s.client.Get(url)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()

	var result prometheusResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return 0, err
	}

	if result.Status != "success" || len(result.Data.Result) == 0 {
		return 0, fmt.Errorf("no data found for query: %s", query)
	}

	// Parse value from ["123456789", "12.5"]
	valStr, ok := result.Data.Result[0].Value[1].(string)
	if !ok {
		return 0, fmt.Errorf("unexpected value format")
	}

	return strconv.ParseFloat(valStr, 64)
}
