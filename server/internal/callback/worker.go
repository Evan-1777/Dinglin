package callback

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"dinglin/server/internal/domain"
	"dinglin/server/internal/notify"
	"dinglin/server/internal/push"
	"dinglin/server/internal/schedule"
	"dinglin/server/internal/store"
)

var retryBackoffs = []time.Duration{
	5 * time.Second,
	30 * time.Second,
	120 * time.Second,
}

type Service struct {
	store         *store.Store
	notifySvc     *notify.Service
	scheduleSvc   *schedule.Service
	dispatcher    *push.Dispatcher
	httpClient    *http.Client
	retentionDays int
}

func NewService(st *store.Store, notifySvc *notify.Service, scheduleSvc *schedule.Service, dispatcher *push.Dispatcher, retentionDays int) *Service {
	return &Service{
		store:         st,
		notifySvc:     notifySvc,
		scheduleSvc:   scheduleSvc,
		dispatcher:    dispatcher,
		httpClient:    &http.Client{Timeout: 10 * time.Second},
		retentionDays: retentionDays,
	}
}

type ReceiptInput struct {
	NotificationID string
	DeviceID       *string
	ActionID       string
	SnoozeMinutes  int
	Payload        map[string]any
}

// SubmitReceipt records a quick receipt, updates notification status, schedules snooze if requested, and enqueues webhook callback.
func (s *Service) SubmitReceipt(ctx context.Context, in ReceiptInput) (domain.Receipt, domain.Notification, error) {
	in.ActionID = strings.TrimSpace(in.ActionID)
	if in.ActionID == "" {
		return domain.Receipt{}, domain.Notification{}, errors.New("action_id is required")
	}

	notif, err := s.notifySvc.GetByID(ctx, in.NotificationID)
	if err != nil {
		return domain.Receipt{}, domain.Notification{}, err
	}

	now := time.Now().UTC()
	actionLabel := in.ActionID
	newStatus := domain.NotificationStatusAcked
	var snoozedUntil *time.Time

	switch in.ActionID {
	case "read":
		actionLabel = "已读"
		newStatus = domain.NotificationStatusRead
	case "ack":
		actionLabel = "确认"
		newStatus = domain.NotificationStatusAcked
	case "dismiss":
		actionLabel = "忽略"
		newStatus = domain.NotificationStatusDismissed
	case "snooze":
		actionLabel = "延后"
		newStatus = domain.NotificationStatusSnoozed
		mins := in.SnoozeMinutes
		if mins <= 0 {
			if cfg, err := s.store.GetSettings(ctx, s.retentionDays); err == nil && cfg.DefaultSnoozeMinutes > 0 {
				mins = cfg.DefaultSnoozeMinutes
			} else {
				mins = 10
			}
		}
		t := now.Add(time.Duration(mins) * time.Minute)
		snoozedUntil = &t
	default:
		for _, a := range notif.Actions {
			if a.ID == in.ActionID {
				actionLabel = a.Label
				break
			}
		}
	}

	// Resolve target callback URL & signing secret
	targetURL := notif.CallbackURL
	var signingSecret string
	if notif.SourceID != nil && *notif.SourceID != "" {
		var srcURL, srcSecret string
		if err := s.store.DB.QueryRowContext(ctx, `SELECT callback_url, callback_secret FROM sources WHERE id = ?`, *notif.SourceID).Scan(&srcURL, &srcSecret); err == nil {
			if targetURL == "" {
				targetURL = srcURL
			}
			signingSecret = srcSecret
		}
	}

	payloadJSON := "{}"
	if len(in.Payload) > 0 {
		if b, err := json.Marshal(in.Payload); err == nil {
			payloadJSON = string(b)
		}
	}

	receipt := domain.Receipt{
		ID:             domain.NewID(),
		NotificationID: notif.ID,
		DeviceID:       in.DeviceID,
		ActionID:       in.ActionID,
		ActionLabel:    actionLabel,
		Payload:        in.Payload,
		CreatedAt:      now,
	}

	tx, err := s.store.DB.BeginTx(ctx, nil)
	if err != nil {
		return domain.Receipt{}, domain.Notification{}, err
	}
	defer func() { _ = tx.Rollback() }()

	_, err = tx.ExecContext(ctx, `
		INSERT INTO receipts (id, notification_id, device_id, action_id, action_label, payload_json, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		receipt.ID, receipt.NotificationID, receipt.DeviceID, receipt.ActionID, receipt.ActionLabel, payloadJSON, now.Unix(),
	)
	if err != nil {
		return domain.Receipt{}, domain.Notification{}, err
	}

	notif.Status = newStatus
	notif.SnoozedUntil = snoozedUntil
	notif.UpdatedAt = now
	_, err = tx.ExecContext(ctx, `
		UPDATE notifications SET status = ?, snoozed_until = ?, updated_at = ? WHERE id = ?`,
		notif.Status, store.NullableUnix(notif.SnoozedUntil), now.Unix(), notif.ID,
	)
	if err != nil {
		return domain.Receipt{}, domain.Notification{}, err
	}

	eventBody := map[string]any{
		"receipt":      receipt,
		"notification": notif,
	}
	seq, eventRaw, err := store.AppendSyncEventTx(ctx, tx, "receipt.created", receipt.ID, eventBody, now)
	if err != nil {
		return domain.Receipt{}, domain.Notification{}, err
	}

	if targetURL != "" && in.ActionID != "read" {
		cbPayload, _ := json.Marshal(map[string]any{
			"event":           "receipt.created",
			"notification_id": notif.ID,
			"receipt_id":      receipt.ID,
			"action_id":       receipt.ActionID,
			"action_label":    receipt.ActionLabel,
			"payload":         receipt.Payload,
			"created_at":      receipt.CreatedAt,
		})
		_, err = tx.ExecContext(ctx, `
			INSERT INTO callback_jobs (id, notification_id, receipt_id, target_url, signing_secret, payload_json, status, attempts, next_attempt_at, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)`,
			domain.NewID(), notif.ID, receipt.ID, targetURL, signingSecret, string(cbPayload),
			domain.CallbackStatusPending, now.Unix(), now.Unix(), now.Unix(),
		)
		if err != nil {
			return domain.Receipt{}, domain.Notification{}, err
		}
	}

	if err := tx.Commit(); err != nil {
		return domain.Receipt{}, domain.Notification{}, err
	}

	// Create one-shot snooze schedule referencing source_notification_id to inherit actions & callback_url.
	if in.ActionID == "snooze" && snoozedUntil != nil && s.scheduleSvc != nil {
		origID := notif.ID
		_, _ = s.scheduleSvc.Create(ctx, schedule.CreateInput{
			SourceID:             notif.SourceID,
			SourceNotificationID: &origID,
			Kind:                 domain.ScheduleKindNotification,
			Title:                notif.Title,
			Body:                 notif.Body,
			Priority:             notif.Priority,
			ScheduleType:         domain.ScheduleTypeOnce,
			FireAt:               snoozedUntil,
		})
	}

	if s.dispatcher != nil {
		s.dispatcher.Broadcast(ctx, push.EventMessage{
			Seq:       seq,
			EventType: "receipt.created",
			EntityID:  receipt.ID,
			Priority:  notif.Priority,
			Title:     notif.Title,
			Data:      eventRaw,
		})
	}

	return receipt, notif, nil
}

func (s *Service) ListReceipts(ctx context.Context, notificationID string) ([]domain.Receipt, error) {
	rows, err := s.store.DB.QueryContext(ctx, `
		SELECT id, notification_id, device_id, action_id, action_label, payload_json, created_at
		FROM receipts WHERE notification_id = ? ORDER BY created_at ASC`, notificationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]domain.Receipt, 0)
	for rows.Next() {
		var (
			r           domain.Receipt
			deviceID    sql.NullString
			payloadJSON string
			createdAt   int64
		)
		if err := rows.Scan(&r.ID, &r.NotificationID, &deviceID, &r.ActionID, &r.ActionLabel, &payloadJSON, &createdAt); err != nil {
			return nil, err
		}
		if deviceID.Valid {
			v := deviceID.String
			r.DeviceID = &v
		}
		_ = json.Unmarshal([]byte(payloadJSON), &r.Payload)
		r.CreatedAt = time.Unix(createdAt, 0).UTC()
		out = append(out, r)
	}
	return out, nil
}

// ComputeSignature computes HMAC-SHA256 hex digest over "timestamp.body".
func ComputeSignature(secret, timestamp string, body []byte) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(timestamp))
	mac.Write([]byte("."))
	mac.Write(body)
	return "sha256=" + hex.EncodeToString(mac.Sum(nil))
}

// ProcessOnce delivers all pending callback jobs whose next_attempt_at <= now.
func (s *Service) ProcessOnce(ctx context.Context, now time.Time) (int, error) {
	rows, err := s.store.DB.QueryContext(ctx, `
		SELECT id, target_url, signing_secret, payload_json, attempts
		FROM callback_jobs
		WHERE status = 'pending' AND next_attempt_at <= ?
		ORDER BY next_attempt_at ASC LIMIT 20`, now.UTC().Unix())
	if err != nil {
		return 0, err
	}
	type jobRow struct {
		id            string
		targetURL     string
		signingSecret string
		payloadJSON   string
		attempts      int
	}
	var jobs []jobRow
	for rows.Next() {
		var j jobRow
		if err := rows.Scan(&j.id, &j.targetURL, &j.signingSecret, &j.payloadJSON, &j.attempts); err == nil {
			jobs = append(jobs, j)
		}
	}
	_ = rows.Close()

	processed := 0
	for _, j := range jobs {
		processed++
		ts := strconv.FormatInt(now.UTC().Unix(), 10)
		body := []byte(j.payloadJSON)
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, j.targetURL, bytes.NewReader(body))
		if err != nil {
			s.markJobFailure(ctx, j.id, j.attempts, 0, err.Error(), now)
			continue
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Dinglin-Event", "receipt.created")
		req.Header.Set("X-Dinglin-Timestamp", ts)
		req.Header.Set("X-Dinglin-Signature", ComputeSignature(j.signingSecret, ts, body))

		resp, err := s.httpClient.Do(req)
		if err != nil {
			s.markJobFailure(ctx, j.id, j.attempts, 0, err.Error(), now)
			continue
		}
		_ = resp.Body.Close()

		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			_, _ = s.store.DB.ExecContext(ctx, `
				UPDATE callback_jobs SET status = 'delivered', attempts = ?, last_http_status = ?, last_error = '', updated_at = ?
				WHERE id = ?`, j.attempts+1, resp.StatusCode, now.UTC().Unix(), j.id)
		} else {
			s.markJobFailure(ctx, j.id, j.attempts, resp.StatusCode, fmt.Sprintf("http %d", resp.StatusCode), now)
		}
	}
	return processed, nil
}

func (s *Service) markJobFailure(ctx context.Context, id string, prevAttempts, httpStatus int, errMsg string, now time.Time) {
	attempts := prevAttempts + 1
	if prevAttempts >= len(retryBackoffs) {
		_, _ = s.store.DB.ExecContext(ctx, `
			UPDATE callback_jobs SET status = 'failed', attempts = ?, last_http_status = ?, last_error = ?, updated_at = ?
			WHERE id = ?`, attempts, httpStatus, errMsg, now.UTC().Unix(), id)
		return
	}
	nextAttempt := now.UTC().Add(retryBackoffs[prevAttempts])
	_, _ = s.store.DB.ExecContext(ctx, `
		UPDATE callback_jobs SET status = 'pending', attempts = ?, next_attempt_at = ?, last_http_status = ?, last_error = ?, updated_at = ?
		WHERE id = ?`, attempts, nextAttempt.Unix(), httpStatus, errMsg, now.UTC().Unix(), id)
}

// StartWorker runs the background callback delivery loop until ctx is cancelled.
func (s *Service) StartWorker(ctx context.Context, interval time.Duration) {
	if interval <= 0 {
		interval = 2 * time.Second
	}
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				_, _ = s.ProcessOnce(ctx, time.Now().UTC())
			}
		}
	}()
}
