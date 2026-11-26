package store

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

func TestOpenMigrateIdempotentAndPragmas(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "dinglin.db")
	st, err := Open(dbPath)
	if err != nil {
		t.Fatalf("Open failed: %v", err)
	}
	defer st.Close()

	ctx := context.Background()
	if err := st.Migrate(ctx); err != nil {
		t.Fatalf("first Migrate failed: %v", err)
	}
	if err := st.Migrate(ctx); err != nil {
		t.Fatalf("second Migrate failed: %v", err)
	}

	var fk int
	if err := st.DB.QueryRowContext(ctx, `PRAGMA foreign_keys`).Scan(&fk); err != nil || fk != 1 {
		t.Fatalf("expected foreign_keys=1, got %d (err=%v)", fk, err)
	}
	var mode string
	if err := st.DB.QueryRowContext(ctx, `PRAGMA journal_mode`).Scan(&mode); err != nil || mode != "wal" {
		t.Fatalf("expected journal_mode=wal, got %q (err=%v)", mode, err)
	}

	// Verify schedules.source_id NULL is accepted with foreign_keys=ON.
	now := time.Now().UTC().Unix()
	if _, err := st.DB.ExecContext(ctx, `
		INSERT INTO schedules (id, kind, title, schedule_type, created_at, updated_at)
		VALUES ('s1', 'alarm', 'Wake', 'once', ?, ?)`, now, now); err != nil {
		t.Fatalf("insert schedule with NULL source_id failed: %v", err)
	}

	// Verify foreign key constraint rejects bogus source_id.
	if _, err := st.DB.ExecContext(ctx, `
		INSERT INTO schedules (id, source_id, kind, title, schedule_type, created_at, updated_at)
		VALUES ('s2', 'nonexistent', 'alarm', 'Bad', 'once', ?, ?)`, now, now); err == nil {
		t.Fatalf("expected foreign key violation for nonexistent source_id")
	}

	// Verify AppendSyncEventTx generates monotonic seq.
	tx, err := st.DB.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("begin tx: %v", err)
	}
	seq1, _, err := AppendSyncEventTx(ctx, tx, "test.a", "e1", map[string]string{"k": "v"}, time.Now())
	if err != nil {
		t.Fatalf("append 1: %v", err)
	}
	seq2, _, err := AppendSyncEventTx(ctx, tx, "test.b", "e2", map[string]string{"k": "v2"}, time.Now())
	if err != nil {
		t.Fatalf("append 2: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit: %v", err)
	}
	if seq2 <= seq1 {
		t.Fatalf("expected monotonic seq, got %d then %d", seq1, seq2)
	}
}
