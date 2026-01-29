// Package domain provides domain level errors & helper structs translated from requests.
package domain

// TaskDetail is an entity that represents task details
type TaskDetail struct {
	ID             int64
	NodeID         string
	CPURequired    float32
	MemoryRequired float32
	DiskRequired   float32
	Priority       int
}
