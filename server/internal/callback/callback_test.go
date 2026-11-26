package callback

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"dinglin/server/internal/domain"
	"dinglin/server/internal/notify"
	"dinglin/server/internal/schedule"
	"dinglin/server/internal/store"
)

func TestReceiptCallbackHMACRetryAndSnoozeInheritance(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "cb.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer st.Close()
	ctx := context.Background()
	if err := st.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	var shouldFail atomic.Bool
	var verified atomic.Bool
	secret := "whsec_test_secret"

	webhookSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if shouldFail.Load() {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		body, _ := io.ReadAll(r.Body)
		ts := r.Header.Get("X-Dinglin-Timestamp")
		sig := r.Header.Get("X-Dinglin-Signature")
		if sig == ComputeSignature(secret, ts, body) && r.Header.Get("X-Dinglin-Event") == "receipt.created" {
			verified.Store(true)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer webhookSrv.Close()

	now := time.Now().UTC().Unix()
	_, err = st.DB.Exec(`
		INSERT INTO sources (id, slug, name, kind, token_hash, token_prefix, callback_url, callback_secret, enabled, created_at, updated_at)
		VALUES ('src1', 'deploy', 'Deploy', 'webhook', 'th1', 'src_1', ?, ?, 1, ?, ?)`,
		webhookSrv.URL, secret, now, now)
	if err != nil {
		t.Fatalf("insert source: %v", err)
	}

	notifySvc := notify.NewService(st, nil)
	schedSvc := schedule.NewService(st, notifySvc, nil)
	cbSvc := NewService(st, notifySvc, schedSvc, nil, 30)

	srcID := "src1"
	notif, _, err := notifySvc.Create(ctx, notify.CreateInput{
		SourceID:    &srcID,
		Title:       "Deploy Approval",
		Body:        "Release v2.0?",
		Priority:    domain.PriorityCritical,
		CallbackURL: webhookSrv.URL,
		Actions: []domain.QuickAction{
			{ID: "approve", Label: "批准发布"},
		},
	})
	if err != nil {
		t.Fatalf("create notif: %v", err)
	}

	// 1. Custom action triggers signed HMAC webhook
	_, updatedNotif, err := cbSvc.SubmitReceipt(ctx, ReceiptInput{
		NotificationID: notif.ID,
		ActionID:       "approve",
	})
	if err != nil || updatedNotif.Status != domain.NotificationStatusAcked {
		t.Fatalf("submit receipt failed: status=%s err=%v", updatedNotif.Status, err)
	}
	if _, err := cbSvc.ProcessOnce(ctx, time.Now().UTC()); err != nil {
		t.Fatalf("process callback: %v", err)
	}
	if !verified.Load() {
		t.Fatalf("expected valid HMAC-SHA256 webhook signature")
	}

	// 2. Snooze creates a schedule that inherits actions & callback_url when fired
	_, _, err = cbSvc.SubmitReceipt(ctx, ReceiptInput{
		NotificationID: notif.ID,
		ActionID:       "snooze",
		SnoozeMinutes:  5,
	})
	if err != nil {
		t.Fatalf("snooze receipt: %v", err)
	}
	scheds, _ := schedSvc.List(ctx, schedule.ListFilter{})
	if len(scheds) != 1 || scheds[0].SourceNotificationID == nil || *scheds[0].SourceNotificationID != notif.ID {
		t.Fatalf("expected 1 snooze schedule linked to original notification, got %+v", scheds)
	}
	// Fast-forward snooze schedule to due and fire it
	past := time.Now().UTC().Add(-time.Minute).Unix()
	_, _ = st.DB.Exec(`UPDATE schedules SET next_fire_at = ? WHERE id = ?`, past, scheds[0].ID)
	if _, err := schedSvc.ProcessDue(ctx, time.Now().UTC()); err != nil {
		t.Fatalf("process due snooze: %v", err)
	}
	notifs, _ := notifySvc.List(ctx, notify.ListFilter{IncludeExpired: true})
	if len(notifs) != 2 {
		t.Fatalf("expected 2 notifications after snooze fires, got %d", len(notifs))
	}
	snoozedNotif := notifs[0] // newest by seq DESC
	if snoozedNotif.CallbackURL != webhookSrv.URL || len(snoozedNotif.Actions) != 1 || snoozedNotif.Actions[0].ID != "approve" {
		t.Fatalf("snoozed notification lost actions/callback_url: %+v", snoozedNotif)
	}

	// 3. Failing webhook retries 3 times then marks failed
	shouldFail.Store(true)
	_, _, err = cbSvc.SubmitReceipt(ctx, ReceiptInput{
		NotificationID: snoozedNotif.ID,
		ActionID:       "ack",
	})
	if err != nil {
		t.Fatalf("submit failing ack: %v", err)
	}
	tCur := time.Now().UTC()
	for _, advance := range []time.Duration{0, 6 * time.Second, 31 * time.Second, 121 * time.Second} {
		tCur = tCur.Add(advance)
		_, _ = cbSvc.ProcessOnce(ctx, tCur)
	}
	var status string
	var attempts int
	err = st.DB.QueryRow(`SELECT status, attempts FROM callback_jobs WHERE notification_id = ? ORDER BY created_at DESC LIMIT 1`, snoozedNotif.ID).Scan(&status, &attempts)
	if err != nil || status != domain.CallbackStatusFailed || attempts != 4 {
		t.Fatalf("expected failed after 4 attempts, got status=%q attempts=%d err=%v", status, attempts, err)
	}
}
