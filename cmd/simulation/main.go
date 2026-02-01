package main

import (
	"context"
	"fmt"
	"log"
	"math/rand"
	"time"

	config "github.com/crabzie/Optimized-RabbitMQ-Scheduler/config/utils"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	simulationDuration = 5 * time.Minute
	injectionInterval  = 5 * time.Second
)

func main() {
	ctx := context.Background()

	// 1. Init Config
	appConfig := config.New()
	log.Println("Starting Scheduler Application")
	log.Printf("DEBUG: Config loaded: %s:%s/%s", appConfig.DB.Host, appConfig.DB.Port, appConfig.DB.Name)

	// Build connection string with CORRECT field (User not Connection)
	connStr := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable&pool_max_conns=10",
		appConfig.DB.User, appConfig.DB.Password, appConfig.DB.Host, appConfig.DB.Port, appConfig.DB.Name)

	fmt.Printf("DEBUG: ConnStr built: postgres://%s:***@%s:%s/%s\n",
		appConfig.DB.User, appConfig.DB.Host, appConfig.DB.Port, appConfig.DB.Name)

	// 2. Connect using pgxpool (native pgx, better than database/sql)
	pool, err := pgxpool.New(ctx, connStr)
	if err != nil {
		log.Fatalf("Failed to create pool: %v", err)
	}
	defer pool.Close()

	// 3. Ping to verify connection
	log.Println("DEBUG: Pinging DB...")
	if err := pool.Ping(ctx); err != nil {
		log.Fatalf("DB unreachable (ensure 'make up' is running): %v", err)
	}

	fmt.Println("✅ DB Ping success!")
	fmt.Println("🚀 Starting 5-minute Traffic Simulation...")
	fmt.Println("   Monitoring Scheduler decisions...")

	endTime := time.Now().Add(simulationDuration)
	ticker := time.NewTicker(injectionInterval)
	defer ticker.Stop()

	// Monitor stats in background
	go monitorAssignments(ctx, pool)

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

				_, err := pool.Exec(ctx, query, taskID, "simulation-job", "alpine", priority, cpu, mem)
				if err != nil {
					log.Printf("❌ Failed to insert task %s: %v", taskID, err)
				} else {
					fmt.Printf("   ✓ Task %s created (Priority: %d, CPU: %.1f, Mem: %.0f MB)\n",
						taskID, priority, cpu, mem)
				}
			}
		}
	}
}

func monitorAssignments(ctx context.Context, pool *pgxpool.Pool) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	lastChecked := time.Now()

	for range ticker.C {
		// Find tasks that changed from PENDING to SCHEDULED/RUNNING recently
		query := `SELECT id, assigned_node_id, status, required_cpu, required_memory FROM tasks
		          WHERE updated_at > $1 AND status != 'PENDING' AND assigned_node_id != ''
		          ORDER BY updated_at DESC`

		rows, err := pool.Query(ctx, query, lastChecked)
		if err != nil {
			log.Printf("Monitor error: %v", err)
			continue
		}

		checkTime := time.Now()
		count := 0

		for rows.Next() {
			var id, node, status string
			var cpu, mem float64
			if err := rows.Scan(&id, &node, &status, &cpu, &mem); err == nil {
				fmt.Printf("   👀 Scheduler assigned %s -> %s (Status: %s, Req: %.1f CPU, %.0f MB)\n",
					id, node, status, cpu, mem)
				count++
			}
		}
		rows.Close()

		if count > 0 {
			fmt.Printf("   📊 Total assignments detected: %d\n", count)
		}

		lastChecked = checkTime
	}
}
