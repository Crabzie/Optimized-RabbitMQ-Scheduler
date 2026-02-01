package main

import (
	"database/sql"
	"fmt"
	"log"
	"math/rand"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

const (
	simulationDuration = 5 * time.Minute
	injectionInterval  = 5 * time.Second
)

func main() {
	// Connect to DB (using standard sql for simplicity in script)
	// Connection string assumes running from host targeting localhost port mapped
	// In docker network it would be "postgres", but for "make test-simulation" running on host, we need localhost
	connStr := "postgres://scheduler:your_postgres_password@localhost:5432/schedulerdb?sslmode=disable"
	db, err := sql.Open("pgx", connStr)
	if err != nil {
		log.Fatal("Failed to connect to DB:", err)
	}
	defer db.Close()

	if err := db.Ping(); err != nil {
		log.Fatal("DB unreachable (ensure 'make up' is running):", err)
	}

	fmt.Println("🚀 Starting 5-minute Traffic Simulation...")
	fmt.Println("   Monitoring Scheduler decisions...")

	endTime := time.Now().Add(simulationDuration)
	ticker := time.NewTicker(injectionInterval)
	defer ticker.Stop()

	// Monitor stats in background
	go monitorAssignments(db)

	taskCount := 0

	for {
		select {
		case <-ticker.C:
			if time.Now().After(endTime) {
				fmt.Println("\n✅ Simulation Complete.")
				return
			}

			// Generate a batch of tasks
			batchSize := rand.Intn(5) + 1 // 1-5 tasks
			fmt.Printf("\n[Generator] Injecting %d new tasks...\n", batchSize)

			for i := 0; i < batchSize; i++ {
				taskCount++
				taskID := fmt.Sprintf("sim-task-%d", taskCount)
				priority := rand.Intn(10) // 0-9

				// Simulate "Tight" constraints randomly
				var cpu, mem float64
				r := rand.Float64()
				if r < 0.3 {
					// Heavy CPU
					cpu = 1.0 + rand.Float64() // 1.0 - 2.0
					mem = 256
				} else if r < 0.6 {
					// Heavy Mem
					cpu = 0.5
					mem = 1024 + rand.Float64()*1024 // 1GB - 2GB
				} else {
					// Lite
					cpu = 0.1
					mem = 128
				}

				query := `INSERT INTO tasks (id, name, image, status, priority, required_cpu, required_memory, created_at, updated_at) 
						  VALUES ($1, $2, $3, 'PENDING', $4, $5, $6, NOW(), NOW())`

				_, err := db.Exec(query, taskID, "simulation-job", "alpine", priority, cpu, mem)
				if err != nil {
					log.Printf("Failed to insert task %s: %v", taskID, err)
				}
			}

		}
	}
}

func monitorAssignments(db *sql.DB) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	lastChecked := time.Now()

	for range ticker.C {
		// Find tasks that changed from PENDING to SCHEDULED/RUNNING recently
		query := `SELECT id, assigned_node_id, status, required_cpu, required_memory FROM tasks 
				  WHERE updated_at > $1 AND status != 'PENDING' AND assigned_node_id != ''
				  ORDER BY updated_at DESC`

		rows, err := db.Query(query, lastChecked)
		if err != nil {
			log.Println("Monitor error:", err)
			continue
		}

		checkTime := time.Now()

		for rows.Next() {
			var id, node, status string
			var cpu, mem float64
			if err := rows.Scan(&id, &node, &status, &cpu, &mem); err == nil {
				fmt.Printf("   👀 Scheduler assigned %s -> %s (Req: %.1f CPU, %.0f MB)\n", id, node, cpu, mem)
			}
		}
		rows.Close()
		lastChecked = checkTime
	}
}
