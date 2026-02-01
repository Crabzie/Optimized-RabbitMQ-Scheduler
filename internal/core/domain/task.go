package domain

import (
	"time"
)

type TaskStatus string

const (
	TaskStatusPending   TaskStatus = "PENDING"
	TaskStatusScheduled TaskStatus = "SCHEDULED"
	TaskStatusRunning   TaskStatus = "RUNNING"
	TaskStatusCompleted TaskStatus = "COMPLETED"
	TaskStatusFailed    TaskStatus = "FAILED"
)

// Task represents a unit of work to be scheduled
type Task struct {
	ID             string     `json:"id"`
	Name           string     `json:"name"`
	Image          string     `json:"image"`           // Docker image to run
	Command        []string   `json:"command"`         // Command to execute
	Priority       int        `json:"priority"`        // 1 (Low) to 10 (Critical)
	RequiredCPU    float64    `json:"required_cpu"`    // Number of cores
	RequiredMemory float64    `json:"required_memory"` // Memory in MB
	Status         TaskStatus `json:"status"`
	AssignedNodeID string     `json:"assigned_node_id,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
}
