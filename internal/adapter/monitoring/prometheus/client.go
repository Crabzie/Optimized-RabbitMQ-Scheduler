package prometheus

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/internal/core/domain"
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
		client:        &http.Client{Timeout: 10 * time.Second},
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
			Value  []interface{}     `json:"value"`
		} `json:"result"`
	} `json:"data"`
	Error     string `json:"error"`
	ErrorType string `json:"errorType"`
}

func (s *monitoringService) GetNodeMetrics(ctx context.Context, nodeID string) (float64, float64, error) {
	// Query CPU Usage directly from Gauge
	cpuQuery := fmt.Sprintf(`node_cpu_usage_percent{instance="%s"}`, nodeID)
	cpuUsage, err := s.queryPrometheus(ctx, cpuQuery)
	if err != nil {
		s.log.Warn("CPU query failed, using fallback", zap.String("node", nodeID), zap.Error(err))
		cpuUsage = 5.0
	}

	// Query Memory Usage directly from Gauge
	memQuery := fmt.Sprintf(`node_memory_usage_bytes{instance="%s"}`, nodeID)
	memUsageBytes, err := s.queryPrometheus(ctx, memQuery)
	if err != nil {
		s.log.Warn("Memory query failed, using fallback", zap.String("node", nodeID), zap.Error(err))
		memUsageBytes = 1024 * 1024 * 1024 // 1GB fallback
	}

	return cpuUsage, memUsageBytes / 1024 / 1024, nil
}

func (s *monitoringService) GetAllNodesMetrics(ctx context.Context) (map[string]domain.NodeMetrics, error) {
	metrics := make(map[string]domain.NodeMetrics)

	// 1. Get all CPU usage
	cpuResults, err := s.queryPrometheusVector(ctx, "node_cpu_usage_percent")
	if err == nil {
		for _, res := range cpuResults {
			instance := res.Metric["instance"]
			val := metrics[instance]
			val.CPUUsage = res.Value
			metrics[instance] = val
		}
	}

	// 2. Get all Mem usage
	memResults, err := s.queryPrometheusVector(ctx, "node_memory_usage_bytes")
	if err == nil {
		for _, res := range memResults {
			instance := res.Metric["instance"]
			val := metrics[instance]
			val.MemUsage = res.Value / 1024 / 1024 // Convert to MB
			metrics[instance] = val
		}
	}

	return metrics, nil
}

func (s *monitoringService) queryPrometheus(ctx context.Context, query string) (float64, error) {
	results, err := s.queryPrometheusVector(ctx, query)
	if err != nil {
		return 0, err
	}
	if len(results) == 0 {
		return 0, nil
	}
	return results[0].Value, nil
}

type vectorResult struct {
	Metric map[string]string
	Value  float64
}

func (s *monitoringService) queryPrometheusVector(ctx context.Context, query string) ([]vectorResult, error) {
	escapedQuery := url.QueryEscape(query)
	reqURL := fmt.Sprintf("%s/api/v1/query?query=%s", s.prometheusURL, escapedQuery)

	req, err := http.NewRequestWithContext(ctx, "GET", reqURL, nil)
	if err != nil {
		return nil, err
	}

	resp, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("prometheus status %d", resp.StatusCode)
	}

	var res prometheusResponse
	if err := json.NewDecoder(resp.Body).Decode(&res); err != nil {
		return nil, err
	}

	var results []vectorResult
	for _, r := range res.Data.Result {
		if len(r.Value) < 2 {
			continue
		}
		valStr, ok := r.Value[1].(string)
		if !ok {
			continue
		}
		val, _ := strconv.ParseFloat(valStr, 64)
		results = append(results, vectorResult{Metric: r.Metric, Value: val})
	}

	return results, nil
}
