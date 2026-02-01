package main

import (
	"context"
	"fmt"
	"log"
	"math/rand"
	"net/url"
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

	appConfig := config.New()
	log.Println("Starting Scheduler Application")
	log.Printf("DEBUG: Config loaded: %s:%s/%s", appConfig.DB.Host, appConfig.DB.Port, appConfig.DB.Name)

	escapedPassword := url.QueryEscape(appConfig.DB.Password)

	connStr := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable&pool_max_conns=10&connect_timeout=5",
		appConfig.DB.User,
		escapedPassword,
		appConfig.DB.Host,
		appConfig.DB.Port,
		appConfig.DB.Name)

	fmt.Printf("DEBUG: ConnStr built: postgres://%s:***@%s:%s/%s\n",
		appConfig.DB.User, appConfig.DB.Host, appConfig.DB.Port, appConfig.DB.Name)

	log.Println("DEBUG: Creating connection pool...")
	pool, err := pgxpool.New(ctx, connStr)
	if err != nil {
		log.Fatalf("Failed to create pool: %v", err)
	}
	defer pool.Close()

	log.Println("DEBUG: Pinging DB...")
	if err := pool.Ping(ctx); err != nil {
		log.Fatalf("DB unreachable: %v", err)
	}

	fmt.Println("✅ DB Ping success!")
	fmt.Println("🚀 Starting 5-minute Traffic Simulation...")
	fmt.Println("   Monitoring Scheduler decisions...")

	endTime := time.Now().Add(simulationDuration)
	ticker := time.NewTicker(injectionInterval)
	defer ticker.Stop()

	go monitorAssignments(ctx, pool)

	taskCount := 0
	for {
		select {
		case <-ticker.C:
			if time.Now().After(endTime) {
				fmt.Println("\n✅ Simulation Complete.")
				return
			}

			batchSize := rand.Intn(5) + 1
			fmt.Printf("\n[Generator] Injecting %d new tasks...\n", batchSize)

			for i := 0; i < batchSize; i++ {
				taskCount++
				taskID := fmt.Sprintf("sim-task-%d", taskCount)
				priority := rand.Intn(10)

				var cpu, mem float64
				r := rand.Float64()
				if r < 0.3 {
					cpu = 1.0 + rand.Float64()
					mem = 256
				} else if r < 0.6 {
					cpu = 0.5
					mem = 1024 + rand.Float64()*1024
				} else {
					cpu = 0.1
					mem = 128
				}

				query := `INSERT INTO tasks (id, name, image, status, priority, required_cpu, required_memory, created_at, updated_at)
				          VALUES ($1, $2, $3, 'PENDING', $4, $5, $6, NOW(), NOW())`

				_, err := pool.Exec(ctx, query, taskID, "simulation-job", "alpine", priority, cpu, mem)
				if err != nil {
					log.Printf("❌ Failed to insert task %s: %v", taskID, err)
				} else {
					fmt.Printf("   ✓ Created: %s (P:%d, CPU:%.1f, Mem:%.0fMB)\n", taskID, priority, cpu, mem)
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
		query := `SELECT id, assigned_node_id, status, required_cpu, required_memory FROM tasks
		          WHERE updated_at > $1 AND status != 'PENDING' AND assigned_node_id != ''
		          ORDER BY updated_at DESC`

		rows, err := pool.Query(ctx, query, lastChecked)
		if err != nil {
			log.Printf("Monitor error: %v", err)
			continue
		}

		checkTime := time.Now()
		for rows.Next() {
			var id, node, status string
			var cpu, mem float64
			if err := rows.Scan(&id, &node, &status, &cpu, &mem); err == nil {
				fmt.Printf("   👀 %s → %s (%s | %.1fCPU %.0fMB)\n", id, node, status, cpu, mem)
			}
		}
		rows.Close()
		lastChecked = checkTime
	}
}
