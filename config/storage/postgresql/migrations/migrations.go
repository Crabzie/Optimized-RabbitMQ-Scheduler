package migrations

import "embed"

// migrationsFS is a filesystem that embeds the migrations folder
//
//go:embed *.sql
var MigrationsFS embed.FS
