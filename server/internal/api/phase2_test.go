package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"dinglin/server/internal/auth"
	"dinglin/server/internal/callback"
	"dinglin/server/internal/config"
	"dinglin/server/internal/notify"
	"dinglin/server/internal/push"
	"dinglin/server/internal/schedule"
	"dinglin/server/internal/store"
)

func setupPhase2API(t *testing.T) http.Handler {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "p2.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	if err := st.Migrate(context.Background()); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	cfg := config.Config{MasterKey: "master-key", RetentionDays: 30}
	authenticator := auth.New(st, cfg.MasterKey)
	hub := push.NewWSHub(st)
	disp := push.NewDispatcher(st, hub, nil)
	notifySvc := notify.NewService(st, disp)
	schedSvc := schedule.NewService(st, notifySvc, disp)
	cbSvc := callback.NewService(st, notifySvc, schedSvc, disp, cfg.RetentionDays)

	srv := NewServer(cfg, st, authenticator)
	srv.RegisterNotificationRoutes(notifySvc)
	srv.RegisterSyncAndPushRoutes(hub, disp)
	srv.RegisterScheduleRoutes(schedSvc)
	srv.RegisterReceiptRoutes(cbSvc, notifySvc)
	return srv.Handler()
}

func TestPhase2NotifyWebhookSyncAndIsolation(t *testing.T) {
	h := setupPhase2API(t)

	// Create Source A and Source B
	createSrc := func(slug string) (string, string) {
		rr := doJSON(t, h, http.MethodPost, "/api/v1/sources", "master-key", map[string]any{
			"slug": slug, "name": slug, "kind": "webhook",
		})
		if rr.Code != http.StatusCreated {
			t.Fatalf("create %s: %d %s", slug, rr.Code, rr.Body.String())
		}
		var out struct {
			Source struct{ ID string } `json:"source"`
			Token  string              `json:"token"`
		}
		_ = json.Unmarshal(rr.Body.Bytes(), &out)
		return out.Source.ID, out.Token
	}

	srcAID, srcAToken := createSrc("src-a")
	_, srcBToken := createSrc("src-b")

	// 1. Idempotent /api/v1/notify
	req1 := httptest.NewRequest(http.MethodPost, "/api/v1/notify", bytes.NewBufferString(`{"title":"CPU High","body":"95%","priority":"critical"}`))
	req1.Header.Set("Authorization", "Bearer "+srcAToken)
	req1.Header.Set("Idempotency-Key", "idem-1")
	rr1 := httptest.NewRecorder()
	h.ServeHTTP(rr1, req1)
	if rr1.Code != http.StatusCreated {
		t.Fatalf("notify 1 got %d: %s", rr1.Code, rr1.Body.String())
	}
	var nResp1 struct {
		Notification struct{ ID string } `json:"notification"`
		Deduplicated bool                `json:"deduplicated"`
	}
	_ = json.Unmarshal(rr1.Body.Bytes(), &nResp1)
	if nResp1.Deduplicated {
		t.Fatalf("first notify should not be deduplicated")
	}

	req2 := httptest.NewRequest(http.MethodPost, "/api/v1/notify", bytes.NewBufferString(`{"title":"CPU High","body":"95%","priority":"critical"}`))
	req2.Header.Set("Authorization", "Bearer "+srcAToken)
	req2.Header.Set("Idempotency-Key", "idem-1")
	rr2 := httptest.NewRecorder()
	h.ServeHTTP(rr2, req2)
	if rr2.Code != http.StatusOK {
		t.Fatalf("notify 2 got %d", rr2.Code)
	}
	var nResp2 struct {
		Notification struct{ ID string } `json:"notification"`
		Deduplicated bool                `json:"deduplicated"`
	}
	_ = json.Unmarshal(rr2.Body.Bytes(), &nResp2)
	if !nResp2.Deduplicated || nResp2.Notification.ID != nResp1.Notification.ID {
		t.Fatalf("expected deduplicated same notification")
	}

	// 2. Webhook plain text with ?token=
	whReq := httptest.NewRequest(http.MethodPost, "/api/v1/webhook/src-a?token="+srcAToken, bytes.NewBufferString("Disk usage 88%"))
	whRR := httptest.NewRecorder()
	h.ServeHTTP(whRR, whReq)
	if whRR.Code != http.StatusCreated {
		t.Fatalf("webhook plain text got %d: %s", whRR.Code, whRR.Body.String())
	}

	// 3. Expired notification skipped in /api/v1/sync
	past := time.Now().UTC().Add(-time.Minute)
	_ = doJSON(t, h, http.MethodPost, "/api/v1/notify", srcAToken, map[string]any{
		"title":      "Expired",
		"expires_at": past,
	})

	rrSync := doJSON(t, h, http.MethodGet, "/api/v1/sync?since_seq=0", "master-key", nil)
	if rrSync.Code != http.StatusOK {
		t.Fatalf("sync got %d", rrSync.Code)
	}
	var syncOut struct {
		Events    []map[string]any `json:"events"`
		LatestSeq int64            `json:"latest_seq"`
	}
	_ = json.Unmarshal(rrSync.Body.Bytes(), &syncOut)
	if len(syncOut.Events) != 2 || syncOut.LatestSeq != 3 {
		t.Fatalf("expected 2 non-expired events and latest_seq=3, got %d events latest_seq=%d", len(syncOut.Events), syncOut.LatestSeq)
	}

	// 4. Filter search by q + source_id + priority
	rrList := doJSON(t, h, http.MethodGet, "/api/v1/notifications?q=CPU&priority=critical&source_id="+srcAID, "master-key", nil)
	if rrList.Code != http.StatusOK {
		t.Fatalf("list got %d", rrList.Code)
	}
	var listOut struct {
		Notifications []map[string]any `json:"notifications"`
	}
	_ = json.Unmarshal(rrList.Body.Bytes(), &listOut)
	if len(listOut.Notifications) != 1 {
		t.Fatalf("expected 1 filtered notification, got %d", len(listOut.Notifications))
	}

	// 5. Receipt submission & source isolation (Source B cannot read Source A's receipts)
	rrRec := doJSON(t, h, http.MethodPost, "/api/v1/notifications/"+nResp1.Notification.ID+"/receipt", "master-key", map[string]any{
		"action_id": "ack",
	})
	if rrRec.Code != http.StatusCreated {
		t.Fatalf("submit receipt got %d: %s", rrRec.Code, rrRec.Body.String())
	}
	rrSrcA := doJSON(t, h, http.MethodGet, "/api/v1/notifications/"+nResp1.Notification.ID+"/receipts", srcAToken, nil)
	if rrSrcA.Code != http.StatusOK {
		t.Fatalf("source A read own receipts got %d", rrSrcA.Code)
	}
	rrSrcB := doJSON(t, h, http.MethodGet, "/api/v1/notifications/"+nResp1.Notification.ID+"/receipts", srcBToken, nil)
	if rrSrcB.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for source B reading source A receipts, got %d", rrSrcB.Code)
	}
}
