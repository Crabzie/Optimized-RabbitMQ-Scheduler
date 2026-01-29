// Package postgres provides PostgresDB server implimentation logic.
package postgres

import (
	"context"
	"fmt"

	"github.com/Masterminds/squirrel"
	"github.com/crabzie/Optimized-RabbitMQ-Scheduler/config/storage/postgresql/migrations"
	config "github.com/crabzie/Optimized-RabbitMQ-Scheduler/config/utils"
	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/postgres"
	"github.com/golang-migrate/migrate/v4/source/iofs"
	zaptracer "github.com/jackc/pgx-zap"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/tracelog"
	"go.uber.org/zap"
)

/**
 * DB is a wrapper for PostgreSQL database connection
 * that uses pgxpool as database driver.
 * It also holds a reference to squirrel.StatementBuilderType
 * which is used to build SQL queries that compatible with PostgreSQL syntax
 */
type DB struct {
	*pgxpool.Pool
	QueryBuilder *squirrel.StatementBuilderType
	url          string
}

// SetPoolConfig takes a database connection url & a logger instance,
// it returns pgxpool.Config instance & an error,
// it sets pgxpool.Config values like consuming the logger to trace db querie's
// & setting MaxConns, it can fail if it can't parse the config from url
func setPoolConfig(url string, logger *zap.Logger) (*pgxpool.Config, error) {
	dbCfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, err
	}
	dbCfg.MaxConns = 1
	dbCfg.ConnConfig.Tracer = &tracelog.TraceLog{
		Logger:   zaptracer.NewLogger(logger),
		LogLevel: tracelog.LogLevelInfo,
	}
	dbCfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeExec
	dbCfg.ConnConfig.StatementCacheCapacity = 0

	return dbCfg, nil
}

// New creates a new PostgreSQL database instance
func New(ctx context.Context, config *config.DB, logger *zap.Logger) (*DB, error) {
	url := fmt.Sprintf("%s://%s:%s@%s:%s/%s?sslmode=disable",
		config.Connection,
		config.User,
		config.Password,
		config.Host,
		config.Port,
		config.Name,
	)

	// Load db config
	dbCfg, err := setPoolConfig(url, logger)
	if err != nil {
		return nil, err
	}

	// create concurrent connection pool
	db, err := pgxpool.NewWithConfig(ctx, dbCfg)
	if err != nil {
		return nil, err
	}

	if err := db.Ping(ctx); err != nil {
		return nil, err
	}

	psql := squirrel.StatementBuilder.PlaceholderFormat(squirrel.Dollar)

	return &DB{
		db,
		&psql,
		url,
	}, nil
}

// Migrate runs the database migration
func (db *DB) Migrate() error {
	driver, err := iofs.New(migrations.MigrationsFS, ".")
	if err != nil {
		return err
	}

	migrations, err := migrate.NewWithSourceInstance("iofs", driver, db.url)
	if err != nil {
		return err
	}

	if err := migrations.Up(); err != nil && err != migrate.ErrNoChange {
		return err
	}

	return nil
}

// DBHealth Check DB health
func (db *DB) DBHealth(ctx context.Context) error {
	if err := db.Ping(ctx); err != nil {
		return err
	}
	return nil
}

// ErrorCode returns the error code of the given error
func (db *DB) ErrorCode(err error) string {
	pgErr := err.(*pgconn.PgError)
	return pgErr.Code
}

// Close closes the database connection
func (db *DB) Close() {
	db.Pool.Close()
}
