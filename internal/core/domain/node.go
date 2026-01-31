package domain

import "time"

type NodeStatus string

const (
	NodeStatusActive   NodeStatus = "ACTIVE"
	NodeStatusInactive NodeStatus = "INACTIVE"
	NodeStatusDraining NodeStatus = "DRAINING"
)

// Node represents a Fog Node independent of the specific worker implementation
type Node struct {
	ID            string     `json:"id"`
	Hostname      string     `json:"hostname"`
	TotalCPU      float64    `json:"total_cpu"`    // Total Cores
	TotalMemory   float64    `json:"total_memory"` // Total MB
	UsedCPU       float64    `json:"used_cpu"`     // Current usage
	UsedMemory    float64    `json:"used_memory"`  // Current usage
	Status        NodeStatus `json:"status"`
	LastHeartbeat time.Time  `json:"last_heartbeat"`
}

// AvailableCPU returns free CPU cores
func (n *Node) AvailableCPU() float64 {
	return n.TotalCPU - n.UsedCPU
}

// AvailableMemory returns free Memory in MB
func (n *Node) AvailableMemory() float64 {
	return n.TotalMemory - n.UsedMemory
}
