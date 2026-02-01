package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
)

// LogEntry matches the Zap JSON structure
type LogEntry struct {
	Level   string `json:"level"`
	Msg     string `json:"msg"`
	TaskID  string `json:"task_id"`
	Status  string `json:"status"`
	NodeID  string `json:"node_id"`
	Service string `json:"service"`
}

const (
	colorReset  = "\033[0m"
	colorRed    = "\033[31m"
	colorGreen  = "\033[32m"
	colorYellow = "\033[33m"
	colorBlue   = "\033[34m"
	colorPurple = "\033[35m"
	colorCyan   = "\033[36m"
	colorGray   = "\033[37m"
)

func main() {
	fmt.Println(colorCyan + "🚀 Fog Node Activity Monitor Starting..." + colorReset)
	fmt.Println(colorGray + "Listening for task events from fog-node-1, fog-node-2, fog-node-3..." + colorReset)
	fmt.Println("-------------------------------------------------------------------------")

	// Use docker service logs with follow and tail
	cmd := exec.Command("docker", "service", "logs", "-f", "fog-scheduler_fog-node-1", "fog-scheduler_fog-node-2", "fog-scheduler_fog-node-3")

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		fmt.Printf("Error creating stdout pipe: %v\n", err)
		return
	}

	if err := cmd.Start(); err != nil {
		fmt.Printf("Error starting docker logs command: %v\n", err)
		return
	}

	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		line := scanner.Text()

		// Docker service logs format: "service_name.instance.id | {JSON}"
		parts := strings.SplitN(line, "|", 2)
		if len(parts) < 2 {
			continue
		}

		serviceLabel := strings.TrimSpace(parts[0])
		jsonPayload := strings.TrimSpace(parts[1])

		var entry LogEntry
		if err := json.Unmarshal([]byte(jsonPayload), &entry); err != nil {
			// Not a JSON log or different format, ignore
			continue
		}

		prettify(serviceLabel, entry)
	}

	if err := cmd.Wait(); err != nil {
		fmt.Printf("Docker command exited: %v\n", err)
	}
}

func prettify(serviceLabel string, entry LogEntry) {
	// Extract node name from service label (e.g., fog-scheduler_fog-node-1.1.xyz -> fog-node-1)
	nodeName := "node"
	if strings.Contains(serviceLabel, "fog-node-1") {
		nodeName = colorBlue + "NODE-1" + colorReset
	} else if strings.Contains(serviceLabel, "fog-node-2") {
		nodeName = colorPurple + "NODE-2" + colorReset
	} else if strings.Contains(serviceLabel, "fog-node-3") {
		nodeName = colorCyan + "NODE-3" + colorReset
	}

	msg := entry.Msg
	taskID := entry.TaskID

	switch {
	case strings.Contains(msg, "Worker received task"):
		fmt.Printf("[%s] 📥 "+colorYellow+"Received Task:"+colorReset+" %s\n", nodeName, taskID)
	case strings.Contains(msg, "Worker registered") || strings.Contains(msg, "Heartbeat"):
		// Skip heartbeats to keep it clean, or show subtle
		// fmt.Printf("[%s] ❤️  Heartbeat sent\n", nodeName)
	case strings.Contains(msg, "Task status updated") && entry.Status == "RUNNING":
		fmt.Printf("[%s] ⚙️  "+colorBlue+"Now Running:"+colorReset+"  %s\n", nodeName, taskID)
	case strings.Contains(msg, "Task finished successfully") || (strings.Contains(msg, "Task status updated") && entry.Status == "COMPLETED"):
		fmt.Printf("[%s] ✅ "+colorGreen+"Task Finished:"+colorReset+" %s\n", nodeName, taskID)
	case entry.Level == "error":
		fmt.Printf("[%s] ❌ "+colorRed+"ERROR:"+colorReset+" %s\n", nodeName, msg)
	}
}
