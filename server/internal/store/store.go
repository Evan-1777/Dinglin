package store

import (
	"context"
	"database/sql"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"dinglin/server/internal/domain"

	_ "modernc.org/sqlite"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// Store wraps the SQLite database handle with single-writer serialization and migration support.
type Store struct {
	DB *sql.DB
}

// Open opens a SQLite database with WAL, foreign keys, and busy timeout applied via DSN PRAGMAs.
func Open(path string) (*Store, error) {
	if path != ":memory:" && !strings.HasPrefix(path, "file:") {
		dir := filepath.Dir(path)
		if dir != "" && dir != "." {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return nil, fmt.Errorf("create db dir: %w", err)
			}
		}
	}

	dsn := buildDSN(path)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	// ponytail: single-writer connection pool eliminates SQLITE_BUSY contention on personal VPS workloads.
	// Upgrade path: split read-only pool if high concurrent read throughput is ever needed.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ping sqlite: %w", err)
	}

	return &Store{DB: db}, nil
}

func buildDSN(path string) string {
	sep := "?"
	if strings.Contains(path, "?") {
		sep = "&"
	}
	return path + sep + "_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)"
}

func (s *Store) Close() error {
	if s == nil || s.DB == nil {
		return nil
	}
	return s.DB.Close()
}

// Migrate applies all embedded SQL migrations idempotently in lexical order.
func (s *Store) Migrate(ctx context.Context) error {
	if _, err := s.DB.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version TEXT PRIMARY KEY,
			applied_at INTEGER NOT NULL
		)`); err != nil {
		return fmt.Errorf("init schema_migrations: %w", err)
	}

	entries, err := fs.ReadDir(migrationsFS, "migrations")
	if err != nil {
		return fmt.Errorf("read migrations dir: %w", err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)

	for _, name := range names {
		var exists int
		err := s.DB.QueryRowContext(ctx, `SELECT 1 FROM schema_migrations WHERE version = ?`, name).Scan(&exists)
		if err == nil {
			continue
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("check migration %s: %w", name, err)
		}

		content, err := fs.ReadFile(migrationsFS, "migrations/"+name)
		if err != nil {
			return fmt.Errorf("read migration %s: %w", name, err)
		}

		tx, err := s.DB.BeginTx(ctx, nil)
		if err != nil {
			return fmt.Errorf("begin migration %s: %w", name, err)
		}
		if _, err := tx.ExecContext(ctx, string(content)); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("exec migration %s: %w", name, err)
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)`, name, time.Now().UTC().Unix()); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("record migration %s: %w", name, err)
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("commit migration %s: %w", name, err)
		}
	}
	return nil
}

// AppendSyncEventTx appends an event to sync_events inside an existing transaction and returns the monotonic seq.
func AppendSyncEventTx(ctx context.Context, tx *sql.Tx, eventType, entityID string, payload any, now time.Time) (int64, json.RawMessage, error) {
	raw, err := json.Marshal(payload)
	if err != nil {
		return 0, nil, fmt.Errorf("marshal sync event payload: %w", err)
	}
	res, err := tx.ExecContext(ctx,
		`INSERT INTO sync_events (event_type, entity_id, payload_json, created_at) VALUES (?, ?, ?, ?)`,
		eventType, entityID, string(raw), now.UTC().Unix(),
	)
	if err != nil {
		return 0, nil, fmt.Errorf("insert sync_event: %w", err)
	}
	seq, err := res.LastInsertId()
	if err != nil {
		return 0, nil, fmt.Errorf("sync_event last_insert_id: %w", err)
	}
	return seq, raw, nil
}

const settingsKey = "system"

// GetSettings loads system settings, falling back to defaults when not persisted yet.
func (s *Store) GetSettings(ctx context.Context, defaultRetentionDays int) (domain.Settings, error) {
	cfg := domain.DefaultSettings(defaultRetentionDays)
	var raw string
	err := s.DB.QueryRowContext(ctx, `SELECT value_json FROM settings WHERE key = ?`, settingsKey).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return cfg, nil
	}
	if err != nil {
		return cfg, fmt.Errorf("query settings: %w", err)
	}
	if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
		return cfg, fmt.Errorf("unmarshal settings: %w", err)
	}
	if cfg.DefaultSnoozeMinutes <= 0 {
		cfg.DefaultSnoozeMinutes = 10
	}
	if cfg.RetentionDays <= 0 {
		cfg.RetentionDays = 30
	}
	return cfg, nil
}

// SaveSettings persists system settings.
func (s *Store) SaveSettings(ctx context.Context, cfg domain.Settings) error {
	raw, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	_, err = s.DB.ExecContext(ctx,
		`INSERT INTO settings (key, value_json, updated_at) VALUES (?, ?, ?)
		 ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at`,
		settingsKey, string(raw), time.Now().UTC().Unix(),
	)
	return err
}

// BoolToInt converts bool to SQLite integer.
func BoolToInt(v bool) int {
	if v {
		return 1
	}
	return 0
}

// NullableUnix converts optional time pointer to Unix seconds.
func NullableUnix(t *time.Time) any {
	if t == nil {
		return nil
	}
	return t.UTC().Unix()
}

// FromNullUnix converts sql.NullInt64 Unix seconds to *time.Time.
func FromNullUnix(v sql.NullInt64) *time.Time {
	if !v.Valid {
		return nil
	}
	t := time.Unix(v.Int64, 0).UTC()
	return &t
}
