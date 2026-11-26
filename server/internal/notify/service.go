package notify

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"dinglin/server/internal/domain"
	"dinglin/server/internal/push"
	"dinglin/server/internal/store"
)

var (
	ErrNotFound   = errors.New("notification not found")
	ErrValidation = errors.New("validation error")
)

type CreateInput struct {
	SourceID       *string
	IdempotencyKey string
	OccurrenceKey  string
	Priority       string
	Title          string
	Body           string
	Category       string
	Actions        []domain.QuickAction
	Metadata       map[string]any
	CallbackURL    string
	ExpiresAt      *time.Time
	ExpiresInSec   int
}

type ListFilter struct {
	Q              string
	SourceID       string
	Priority       string
	Status         string
	IncludeExpired bool
	Limit          int
	BeforeSeq      int64
}

type Service struct {
	store      *store.Store
	dispatcher *push.Dispatcher
}

func NewService(st *store.Store, dispatcher *push.Dispatcher) *Service {
	return &Service{store: st, dispatcher: dispatcher}
}

// Create persists a notification idempotently, appends a sync_event, and broadcasts it.
func (s *Service) Create(ctx context.Context, in CreateInput) (domain.Notification, bool, error) {
	in.Title = strings.TrimSpace(in.Title)
	if in.Title == "" {
		return domain.Notification{}, false, fmt.Errorf("%w: title is required", ErrValidation)
	}
	in.Priority = strings.TrimSpace(in.Priority)
	if in.Priority == "" {
		in.Priority = domain.PriorityNormal
	}
	if !domain.ValidPriority(in.Priority) {
		return domain.Notification{}, false, fmt.Errorf("%w: invalid priority %q", ErrValidation, in.Priority)
	}
	in.IdempotencyKey = strings.TrimSpace(in.IdempotencyKey)
	in.OccurrenceKey = strings.TrimSpace(in.OccurrenceKey)

	now := time.Now().UTC()
	var expiresAt *time.Time
	if in.ExpiresAt != nil {
		t := in.ExpiresAt.UTC()
		expiresAt = &t
	} else if in.ExpiresInSec > 0 {
		t := now.Add(time.Duration(in.ExpiresInSec) * time.Second)
		expiresAt = &t
	}

	tx, err := s.store.DB.BeginTx(ctx, nil)
	if err != nil {
		return domain.Notification{}, false, err
	}
	defer func() { _ = tx.Rollback() }()

	// Idempotency check by (source_id, idempotency_key)
	if in.IdempotencyKey != "" && in.SourceID != nil && *in.SourceID != "" {
		if existing, ok, err := queryNotificationTx(ctx, tx,
			`WHERE source_id = ? AND idempotency_key = ?`, *in.SourceID, in.IdempotencyKey); err != nil {
			return domain.Notification{}, false, err
		} else if ok {
			return existing, true, nil
		}
	}
	// Deduplication check by occurrence_key
	if in.OccurrenceKey != "" {
		if existing, ok, err := queryNotificationTx(ctx, tx,
			`WHERE occurrence_key = ?`, in.OccurrenceKey); err != nil {
			return domain.Notification{}, false, err
		} else if ok {
			return existing, true, nil
		}
	}

	actionsJSON := "[]"
	if len(in.Actions) > 0 {
		if b, err := json.Marshal(in.Actions); err == nil {
			actionsJSON = string(b)
		}
	}
	metaJSON := "{}"
	if len(in.Metadata) > 0 {
		if b, err := json.Marshal(in.Metadata); err == nil {
			metaJSON = string(b)
		}
	}

	var idempPtr, occPtr *string
	if in.IdempotencyKey != "" {
		v := in.IdempotencyKey
		idempPtr = &v
	}
	if in.OccurrenceKey != "" {
		v := in.OccurrenceKey
		occPtr = &v
	}

	notif := domain.Notification{
		ID:             domain.NewID(),
		SourceID:       in.SourceID,
		IdempotencyKey: idempPtr,
		OccurrenceKey:  occPtr,
		Priority:       in.Priority,
		Title:          in.Title,
		Body:           in.Body,
		Category:       strings.TrimSpace(in.Category),
		Actions:        in.Actions,
		Metadata:       in.Metadata,
		CallbackURL:    strings.TrimSpace(in.CallbackURL),
		Status:         domain.NotificationStatusUnread,
		ExpiresAt:      expiresAt,
		CreatedAt:      now,
		UpdatedAt:      now,
	}

	_, err = tx.ExecContext(ctx, `
		INSERT INTO notifications (
			id, seq, source_id, idempotency_key, occurrence_key, priority, title, body, category,
			actions_json, metadata_json, callback_url, status, expires_at, created_at, updated_at
		) VALUES (?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		notif.ID, notif.SourceID, notif.IdempotencyKey, notif.OccurrenceKey, notif.Priority,
		notif.Title, notif.Body, notif.Category, actionsJSON, metaJSON, notif.CallbackURL,
		notif.Status, store.NullableUnix(notif.ExpiresAt), now.Unix(), now.Unix(),
	)
	if err != nil {
		return domain.Notification{}, false, err
	}

	seq, payloadRaw, err := store.AppendSyncEventTx(ctx, tx, "notification.created", notif.ID, notif, now)
	if err != nil {
		return domain.Notification{}, false, err
	}
	notif.Seq = seq
	// Update notification.seq and keep event payload consistent with seq.
	if _, err := tx.ExecContext(ctx, `UPDATE notifications SET seq = ? WHERE id = ?`, seq, notif.ID); err != nil {
		return domain.Notification{}, false, err
	}
	if updatedRaw, err := json.Marshal(notif); err == nil {
		payloadRaw = updatedRaw
		_, _ = tx.ExecContext(ctx, `UPDATE sync_events SET payload_json = ? WHERE seq = ?`, string(updatedRaw), seq)
	}

	if err := tx.Commit(); err != nil {
		return domain.Notification{}, false, err
	}

	if s.dispatcher != nil {
		s.dispatcher.Broadcast(ctx, push.EventMessage{
			Seq:       seq,
			EventType: "notification.created",
			EntityID:  notif.ID,
			Priority:  notif.Priority,
			Title:     notif.Title,
			Data:      payloadRaw,
		})
	}

	return notif, false, nil
}

func (s *Service) GetByID(ctx context.Context, id string) (domain.Notification, error) {
	n, ok, err := queryNotification(ctx, s.store.DB, `WHERE id = ?`, id)
	if err != nil {
		return domain.Notification{}, err
	}
	if !ok {
		return domain.Notification{}, ErrNotFound
	}
	return n, nil
}

func (s *Service) List(ctx context.Context, f ListFilter) ([]domain.Notification, error) {
	if f.Limit <= 0 || f.Limit > 200 {
		f.Limit = 50
	}
	var where []string
	var args []any

	if f.Q != "" {
		like := "%" + f.Q + "%"
		where = append(where, `(title LIKE ? OR body LIKE ? OR category LIKE ?)`)
		args = append(args, like, like, like)
	}
	if f.SourceID != "" {
		where = append(where, `source_id = ?`)
		args = append(args, f.SourceID)
	}
	if f.Priority != "" {
		where = append(where, `priority = ?`)
		args = append(args, f.Priority)
	}
	if f.Status != "" {
		where = append(where, `status = ?`)
		args = append(args, f.Status)
	}
	if !f.IncludeExpired {
		where = append(where, `(expires_at IS NULL OR expires_at > ?)`)
		args = append(args, time.Now().UTC().Unix())
	}
	if f.BeforeSeq > 0 {
		where = append(where, `seq < ?`)
		args = append(args, f.BeforeSeq)
	}

	q := `SELECT id, seq, source_id, idempotency_key, occurrence_key, priority, title, body, category,
		actions_json, metadata_json, callback_url, status, snoozed_until, expires_at, created_at, updated_at
		FROM notifications`
	if len(where) > 0 {
		q += " WHERE " + strings.Join(where, " AND ")
	}
	q += " ORDER BY seq DESC LIMIT ?"
	args = append(args, f.Limit)

	rows, err := s.store.DB.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]domain.Notification, 0)
	for rows.Next() {
		n, err := scanNotification(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, nil
}

// MarkAllRead marks unread notifications (optionally filtered by sourceID) as read and emits a sync event.
func (s *Service) MarkAllRead(ctx context.Context, sourceID string) (int64, error) {
	sourceID = strings.TrimSpace(sourceID)
	now := time.Now().UTC()

	tx, err := s.store.DB.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()

	query := `UPDATE notifications SET status = ?, updated_at = ? WHERE status = ?`
	args := []any{domain.NotificationStatusRead, now.Unix(), domain.NotificationStatusUnread}
	if sourceID != "" {
		query += ` AND source_id = ?`
		args = append(args, sourceID)
	}
	res, err := tx.ExecContext(ctx, query, args...)
	if err != nil {
		return 0, err
	}
	count, err := res.RowsAffected()
	if err != nil {
		return 0, err
	}
	if count == 0 {
		return 0, nil
	}

	entityID := sourceID
	if entityID == "" {
		entityID = "all"
	}
	payload := map[string]any{
		"source_id":  sourceID,
		"count":      count,
		"updated_at": now,
	}
	seq, payloadRaw, err := store.AppendSyncEventTx(ctx, tx, "notifications.read_all", entityID, payload, now)
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}

	if s.dispatcher != nil {
		s.dispatcher.Broadcast(ctx, push.EventMessage{
			Seq:       seq,
			EventType: "notifications.read_all",
			EntityID:  entityID,
			Data:      payloadRaw,
		})
	}
	return count, nil
}

// CleanupExpired deletes notifications older than retention_days or past expires_at by more than 24h.
func (s *Service) CleanupExpired(ctx context.Context, defaultRetentionDays int) (int64, error) {
	cfg, err := s.store.GetSettings(ctx, defaultRetentionDays)
	if err != nil {
		return 0, err
	}
	cutoff := time.Now().UTC().AddDate(0, 0, -cfg.RetentionDays).Unix()
	res, err := s.store.DB.ExecContext(ctx, `DELETE FROM notifications WHERE created_at < ?`, cutoff)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// StartRetentionCleaner runs periodic retention cleanup until ctx is cancelled.
func (s *Service) StartRetentionCleaner(ctx context.Context, defaultRetentionDays int) {
	go func() {
		ticker := time.NewTicker(1 * time.Hour)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				_, _ = s.CleanupExpired(ctx, defaultRetentionDays)
			}
		}
	}()
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanNotification(r rowScanner) (domain.Notification, error) {
	var (
		n            domain.Notification
		sourceID     sql.NullString
		idempKey     sql.NullString
		occKey       sql.NullString
		actionsJSON  string
		metadataJSON string
		snoozedUntil sql.NullInt64
		expiresAt    sql.NullInt64
		createdAt    int64
		updatedAt    int64
	)
	if err := r.Scan(
		&n.ID, &n.Seq, &sourceID, &idempKey, &occKey, &n.Priority, &n.Title, &n.Body, &n.Category,
		&actionsJSON, &metadataJSON, &n.CallbackURL, &n.Status, &snoozedUntil, &expiresAt, &createdAt, &updatedAt,
	); err != nil {
		return domain.Notification{}, err
	}
	if sourceID.Valid {
		v := sourceID.String
		n.SourceID = &v
	}
	if idempKey.Valid {
		v := idempKey.String
		n.IdempotencyKey = &v
	}
	if occKey.Valid {
		v := occKey.String
		n.OccurrenceKey = &v
	}
	_ = json.Unmarshal([]byte(actionsJSON), &n.Actions)
	_ = json.Unmarshal([]byte(metadataJSON), &n.Metadata)
	n.SnoozedUntil = store.FromNullUnix(snoozedUntil)
	n.ExpiresAt = store.FromNullUnix(expiresAt)
	n.CreatedAt = time.Unix(createdAt, 0).UTC()
	n.UpdatedAt = time.Unix(updatedAt, 0).UTC()
	return n, nil
}

func queryNotificationTx(ctx context.Context, tx *sql.Tx, where string, args ...any) (domain.Notification, bool, error) {
	row := tx.QueryRowContext(ctx, `
		SELECT id, seq, source_id, idempotency_key, occurrence_key, priority, title, body, category,
			actions_json, metadata_json, callback_url, status, snoozed_until, expires_at, created_at, updated_at
		FROM notifications `+where, args...)
	n, err := scanNotification(row)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Notification{}, false, nil
	}
	if err != nil {
		return domain.Notification{}, false, err
	}
	return n, true, nil
}

func queryNotification(ctx context.Context, db *sql.DB, where string, args ...any) (domain.Notification, bool, error) {
	row := db.QueryRowContext(ctx, `
		SELECT id, seq, source_id, idempotency_key, occurrence_key, priority, title, body, category,
			actions_json, metadata_json, callback_url, status, snoozed_until, expires_at, created_at, updated_at
		FROM notifications `+where, args...)
	n, err := scanNotification(row)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Notification{}, false, nil
	}
	if err != nil {
		return domain.Notification{}, false, err
	}
	return n, true, nil
}
