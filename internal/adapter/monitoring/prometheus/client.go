package prometheus

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
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

func NewMonitoringService(promURL string, log *zap.Logger) port.MonitoringService {
	return &monitoringService{
		prometheusURL: promURL,
		client:        &http.Client{Timeout: 5 * time.Second},
		log:           log,
	}
}

// Prometheus API response structure
type prometheusResponse struct {
	Status string `json:"status"`
	Data   struct {
		ResultType string `json:"resultType"`
		Result     []struct {
			Metric map[string]string `json:"metric"`
			Value  interface{}       `json:"value"`
		} `json:"result"`
	} `json:"data"`
	Error     string `json:"error"`
	ErrorType string `json:"errorType"`
}

func (s *monitoringService) GetNodeMetrics(ctx context.Context, nodeID string) (float64, float64, error) {
	// Query CPU Usage (percent)
	cpuQuery := fmt.Sprintf(`100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle",instance="%s"}[1m])) * 100)`, nodeID)

	cpuUsage, err := s.queryPrometheus(ctx, cpuQuery)
	if err != nil {
		s.log.Warn("CPU query failed, using simulated metrics",
			zap.String("node", nodeID),
			zap.Error(err))
		return 50.0, 2048.0, nil // Fallback: 50% CPU, 2GB RAM
	}

	// Query Memory Usage (bytes)
	memQuery := fmt.Sprintf(`node_memory_MemTotal_bytes{instance="%s"} - node_memory_MemAvailable_bytes{instance="%s"}`, nodeID, nodeID)

	memUsage, err := s.queryPrometheus(ctx, memQuery)
	if err != nil {
		s.log.Warn("Memory query failed, using partial fallback",
			zap.String("node", nodeID),
			zap.Error(err))
		return cpuUsage, 2048.0, nil // Partial fallback
	}

	return cpuUsage, memUsage / 1024 / 1024, nil // Convert bytes to MB
}

func (s *monitoringService) queryPrometheus(ctx context.Context, query string) (float64, error) {
	// URL-encode query
	escapedQuery := url.QueryEscape(query)
	reqURL := fmt.Sprintf("%s/api/v1/query?query=%s", s.prometheusURL, escapedQuery)

	req, err := http.NewRequestWithContext(ctx, "GET", reqURL, nil)
	if err != nil {
		return 0, fmt.Errorf("failed to create request: %w", err)
	}

	resp, err := s.client.Do(req)
	if err != nil {
		return 0, fmt.Errorf("HTTP request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return 0, fmt.Errorf("prometheus returned status %d: %s", resp.StatusCode, string(body))
	}

	var result prometheusResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return 0, fmt.Errorf("JSON decode failed: %w", err)
	}

	// Check for Prometheus error response
	if result.Status != "success" {
		return 0, fmt.Errorf("prometheus error: %s (%s)", result.Error, result.ErrorType)
	}

	if len(result.Data.Result) == 0 {
		return 0, fmt.Errorf("no data returned for query: %s", query)
	}

	// Parse value - handle BOTH formats
	value := result.Data.Result[0].Value

	switch v := value.(type) {
	case []interface{}:
		// Standard format: [timestamp, "value"]
		if len(v) < 2 {
			return 0, fmt.Errorf("unexpected value array length: %d", len(v))
		}

		// Value is at index 1
		switch valRaw := v[1].(type) {
		case string:
			return strconv.ParseFloat(valRaw, 64)
		case float64:
			return valRaw, nil
		default:
			return 0, fmt.Errorf("unexpected value type in array: %T", valRaw)
		}

	case float64:
		// Direct number format
		return v, nil

	case string:
		// String number
		return strconv.ParseFloat(v, 64)

	default:
		return 0, fmt.Errorf("unexpected value format: %T (%v)", value, value)
	}
}
