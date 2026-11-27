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

func TestPhase1DevicePushModeReadAllScheduleTypeAndDNDValidation(t *testing.T) {
	h := setupPhase2API(t)

	// Create two sources and notifications
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
	srcAID, srcAToken := createSrc("src-read-a")
	_, srcBToken := createSrc("src-read-b")

	// Pair Android and Web devices
	pairDevice := func(name, platform string, hasGMS bool) string {
		codeRR := doJSON(t, h, http.MethodPost, "/api/v1/pairing-codes", "master-key", nil)
		var codeOut struct{ Code string `json:"code"` }
		_ = json.Unmarshal(codeRR.Body.Bytes(), &codeOut)
		pairRR := doJSON(t, h, http.MethodPost, "/api/v1/devices/pair", "", map[string]any{
			"code": codeOut.Code, "name": name, "platform": platform, "has_gms": hasGMS,
		})
		if pairRR.Code != http.StatusCreated {
			t.Fatalf("pair %s: %d %s", name, pairRR.Code, pairRR.Body.String())
		}
		var pairOut struct{ DeviceID string `json:"device_id"` }
		_ = json.Unmarshal(pairRR.Body.Bytes(), &pairOut)
		return pairOut.DeviceID
	}

	androidID := pairDevice("Pixel", "android", true)
	webID := pairDevice("Chrome", "web", false)

	// 1. Update device push_mode (reject fcm without fcm_token; token refresh preserves manual ws)
	if rr := doJSON(t, h, http.MethodPatch, "/api/v1/devices/"+androidID, "master-key", map[string]any{"push_mode": "fcm"}); rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 switching to fcm without fcm_token, got %d", rr.Code)
	}
	if rr := doJSON(t, h, http.MethodPost, "/api/v1/devices/"+androidID+"/fcm-token", "master-key", map[string]any{
		"fcm_token": "tok-initial", "has_gms": true,
	}); rr.Code != http.StatusOK {
		t.Fatalf("register initial fcm token got %d: %s", rr.Code, rr.Body.String())
	}
	rr := doJSON(t, h, http.MethodPatch, "/api/v1/devices/"+androidID, "master-key", map[string]any{"push_mode": "ws"})
	if rr.Code != http.StatusOK {
		t.Fatalf("set android ws got %d: %s", rr.Code, rr.Body.String())
	}
	var devOut struct {
		Device struct {
			PushMode string `json:"push_mode"`
		} `json:"device"`
	}
	_ = json.Unmarshal(rr.Body.Bytes(), &devOut)
	if devOut.Device.PushMode != "ws" {
		t.Fatalf("expected push_mode=ws, got %q", devOut.Device.PushMode)
	}
	// Token refresh without explicit push_mode must preserve manual ws override
	rrRefresh := doJSON(t, h, http.MethodPost, "/api/v1/devices/"+androidID+"/fcm-token", "master-key", map[string]any{
		"fcm_token": "tok-rotated", "has_gms": true,
	})
	if rrRefresh.Code != http.StatusOK {
		t.Fatalf("refresh fcm token got %d: %s", rrRefresh.Code, rrRefresh.Body.String())
	}
	var refreshOut struct {
		PushMode string `json:"push_mode"`
	}
	_ = json.Unmarshal(rrRefresh.Body.Bytes(), &refreshOut)
	if refreshOut.PushMode != "ws" {
		t.Fatalf("expected manual ws preserved on token refresh, got %q", refreshOut.PushMode)
	}
	if rr := doJSON(t, h, http.MethodPatch, "/api/v1/devices/"+androidID, "master-key", map[string]any{"push_mode": "bogus"}); rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 on invalid push_mode, got %d", rr.Code)
	}
	if rr := doJSON(t, h, http.MethodPatch, "/api/v1/devices/"+webID, "master-key", map[string]any{"push_mode": "fcm"}); rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 setting fcm on web device, got %d", rr.Code)
	}

	// 2. Batch mark read-all scoped by source_id without overwriting acked status
	rrN1 := doJSON(t, h, http.MethodPost, "/api/v1/notify", srcAToken, map[string]any{"title": "A1"})
	var n1Out struct{ Notification struct{ ID string } `json:"notification"` }
	_ = json.Unmarshal(rrN1.Body.Bytes(), &n1Out)
	_ = doJSON(t, h, http.MethodPost, "/api/v1/notify", srcAToken, map[string]any{"title": "A2"})
	_ = doJSON(t, h, http.MethodPost, "/api/v1/notify", srcBToken, map[string]any{"title": "B1"})
	_ = doJSON(t, h, http.MethodPost, "/api/v1/notifications/"+n1Out.Notification.ID+"/receipt", "master-key", map[string]any{"action_id": "ack"})

	rrReadA := doJSON(t, h, http.MethodPost, "/api/v1/notifications/read-all", "master-key", map[string]any{"source_id": srcAID})
	if rrReadA.Code != http.StatusOK {
		t.Fatalf("read-all srcA got %d: %s", rrReadA.Code, rrReadA.Body.String())
	}
	var readAOut struct{ Updated int64 `json:"updated"` }
	_ = json.Unmarshal(rrReadA.Body.Bytes(), &readAOut)
	if readAOut.Updated != 1 {
		t.Fatalf("expected 1 unread in srcA updated, got %d", readAOut.Updated)
	}

	// Verify acked status preserved & sync event emitted
	rrSync := doJSON(t, h, http.MethodGet, "/api/v1/sync?since_seq=0", "master-key", nil)
	var syncOut struct {
		Events []struct {
			EventType string `json:"event_type"`
		} `json:"events"`
	}
	_ = json.Unmarshal(rrSync.Body.Bytes(), &syncOut)
	foundReadAll := false
	for _, ev := range syncOut.Events {
		if ev.EventType == "notifications.read_all" {
			foundReadAll = true
		}
	}
	if !foundReadAll {
		t.Fatalf("expected notifications.read_all event in sync feed")
	}

	// 3. Schedule update switching once <-> cron
	fireAt := time.Now().UTC().Add(2 * time.Hour)
	rrCreateSched := doJSON(t, h, http.MethodPost, "/api/v1/schedules", "master-key", map[string]any{
		"kind": "alarm", "title": "Standup", "schedule_type": "once", "fire_at": fireAt, "timezone": "Asia/Shanghai",
	})
	if rrCreateSched.Code != http.StatusCreated {
		t.Fatalf("create schedule got %d: %s", rrCreateSched.Code, rrCreateSched.Body.String())
	}
	var scOut struct{ Schedule struct{ ID string } `json:"schedule"` }
	_ = json.Unmarshal(rrCreateSched.Body.Bytes(), &scOut)

	rrToCron := doJSON(t, h, http.MethodPatch, "/api/v1/schedules/"+scOut.Schedule.ID, "master-key", map[string]any{
		"schedule_type": "cron", "cron_expr": "0 9 * * 1-5",
	})
	if rrToCron.Code != http.StatusOK {
		t.Fatalf("switch once -> cron got %d: %s", rrToCron.Code, rrToCron.Body.String())
	}
	var scCron struct {
		Schedule struct {
			ScheduleType string     `json:"schedule_type"`
			CronExpr     string     `json:"cron_expr"`
			FireAt       *time.Time `json:"fire_at"`
		} `json:"schedule"`
	}
	_ = json.Unmarshal(rrToCron.Body.Bytes(), &scCron)
	if scCron.Schedule.ScheduleType != "cron" || scCron.Schedule.CronExpr != "0 9 * * 1-5" || scCron.Schedule.FireAt != nil {
		t.Fatalf("unexpected cron switch result: %+v", scCron.Schedule)
	}

	rrToOnce := doJSON(t, h, http.MethodPatch, "/api/v1/schedules/"+scOut.Schedule.ID, "master-key", map[string]any{
		"schedule_type": "once", "fire_at": fireAt,
	})
	if rrToOnce.Code != http.StatusOK {
		t.Fatalf("switch cron -> once got %d: %s", rrToOnce.Code, rrToOnce.Body.String())
	}
	var scOnce struct {
		Schedule struct {
			ScheduleType string     `json:"schedule_type"`
			CronExpr     string     `json:"cron_expr"`
			FireAt       *time.Time `json:"fire_at"`
		} `json:"schedule"`
	}
	_ = json.Unmarshal(rrToOnce.Body.Bytes(), &scOnce)
	if scOnce.Schedule.ScheduleType != "once" || scOnce.Schedule.CronExpr != "" || scOnce.Schedule.FireAt == nil {
		t.Fatalf("unexpected once switch result: %+v", scOnce.Schedule)
	}

	// Dismiss completed once schedule, then switch to cron -> resets to active
	if rr := doJSON(t, h, http.MethodPost, "/api/v1/schedules/"+scOut.Schedule.ID+"/dismiss", "master-key", nil); rr.Code != http.StatusOK {
		t.Fatalf("dismiss schedule got %d", rr.Code)
	}
	rrReenable := doJSON(t, h, http.MethodPatch, "/api/v1/schedules/"+scOut.Schedule.ID, "master-key", map[string]any{
		"schedule_type": "cron", "cron_expr": "30 8 * * *",
	})
	if rrReenable.Code != http.StatusOK {
		t.Fatalf("switch completed once -> cron got %d: %s", rrReenable.Code, rrReenable.Body.String())
	}
	var scReactivated struct {
		Schedule struct {
			State   string `json:"state"`
			Enabled bool   `json:"enabled"`
		} `json:"schedule"`
	}
	_ = json.Unmarshal(rrReenable.Body.Bytes(), &scReactivated)
	if scReactivated.Schedule.State != "active" || !scReactivated.Schedule.Enabled {
		t.Fatalf("expected reactivated cron schedule, got %+v", scReactivated.Schedule)
	}

	// 4. DND HH:MM validation
	if rr := doJSON(t, h, http.MethodPatch, "/api/v1/settings", "master-key", map[string]any{"dnd_start": "25:99"}); rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 on invalid dnd_start, got %d", rr.Code)
	}
	if rr := doJSON(t, h, http.MethodPatch, "/api/v1/settings", "master-key", map[string]any{"dnd_end": "9:00"}); rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 on invalid dnd_end, got %d", rr.Code)
	}
	if rr := doJSON(t, h, http.MethodPatch, "/api/v1/settings", "master-key", map[string]any{"dnd_start": "22:30", "dnd_end": "07:15"}); rr.Code != http.StatusOK {
		t.Fatalf("expected 200 on valid dnd times, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestNotificationDeleteBatchClearReadAndAlarmTriggeredNil(t *testing.T) {
	h := setupPhase2API(t)

	createSrc := func(slug string) (string, string) {
		rr := doJSON(t, h, http.MethodPost, "/api/v1/sources", "master-key", map[string]any{
			"slug": slug, "name": slug, "kind": "webhook",
		})
		var out struct {
			Source struct{ ID string } `json:"source"`
			Token  string              `json:"token"`
		}
		_ = json.Unmarshal(rr.Body.Bytes(), &out)
		return out.Source.ID, out.Token
	}
	srcAID, srcAToken := createSrc("batch-a")
	_, srcBToken := createSrc("batch-b")

	send := func(tok, title string) string {
		rr := doJSON(t, h, http.MethodPost, "/api/v1/notify", tok, map[string]any{"title": title})
		if rr.Code != http.StatusCreated {
			t.Fatalf("notify %s: %d %s", title, rr.Code, rr.Body.String())
		}
		var out struct {
			Notification struct{ ID string } `json:"notification"`
		}
		_ = json.Unmarshal(rr.Body.Bytes(), &out)
		return out.Notification.ID
	}

	n1 := send(srcAToken, "N1")
	n2 := send(srcAToken, "N2")
	n3 := send(srcAToken, "N3")
	n4 := send(srcBToken, "N4")

	// Unauthorized access rejected
	if rr := doJSON(t, h, http.MethodDelete, "/api/v1/notifications/"+n1, "", nil); rr.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 on unauth delete, got %d", rr.Code)
	}
	if rr := doJSON(t, h, http.MethodPost, "/api/v1/notifications/batch", "", map[string]any{"action": "read", "ids": []string{n1}}); rr.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 on unauth batch, got %d", rr.Code)
	}

	// Single delete 404 & 200
	if rr := doJSON(t, h, http.MethodDelete, "/api/v1/notifications/missing-id", "master-key", nil); rr.Code != http.StatusNotFound {
		t.Fatalf("expected 404 on missing delete, got %d", rr.Code)
	}
	if rr := doJSON(t, h, http.MethodDelete, "/api/v1/notifications/"+n1, "master-key", nil); rr.Code != http.StatusOK {
		t.Fatalf("expected 200 on delete n1, got %d: %s", rr.Code, rr.Body.String())
	}

	// Batch validation errors
	if rr := doJSON(t, h, http.MethodPost, "/api/v1/notifications/batch", "master-key", map[string]any{"action": "bogus", "ids": []string{n2}}); rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 on invalid action, got %d", rr.Code)
	}
	if rr := doJSON(t, h, http.MethodPost, "/api/v1/notifications/batch", "master-key", map[string]any{"action": "read", "ids": []string{}}); rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 on empty ids, got %d", rr.Code)
	}

	// Batch read -> unread -> read
	rrBatchRead := doJSON(t, h, http.MethodPost, "/api/v1/notifications/batch", "master-key", map[string]any{
		"action": "read", "ids": []string{n2, n3, n4},
	})
	if rrBatchRead.Code != http.StatusOK {
		t.Fatalf("batch read got %d: %s", rrBatchRead.Code, rrBatchRead.Body.String())
	}
	var batchOut struct {
		Affected int64 `json:"affected"`
	}
	_ = json.Unmarshal(rrBatchRead.Body.Bytes(), &batchOut)
	if batchOut.Affected != 3 {
		t.Fatalf("expected 3 affected on batch read, got %d", batchOut.Affected)
	}

	rrBatchUnread := doJSON(t, h, http.MethodPost, "/api/v1/notifications/batch", "master-key", map[string]any{
		"action": "unread", "ids": []string{n3},
	})
	if rrBatchUnread.Code != http.StatusOK {
		t.Fatalf("batch unread got %d", rrBatchUnread.Code)
	}

	// Clear read scoped to srcA -> deletes only n2 (n3 is unread, n4 belongs to srcB)
	rrClearA := doJSON(t, h, http.MethodPost, "/api/v1/notifications/clear-read", "master-key", map[string]any{
		"source_id": srcAID,
	})
	if rrClearA.Code != http.StatusOK {
		t.Fatalf("clear-read srcA got %d: %s", rrClearA.Code, rrClearA.Body.String())
	}
	var clearOut struct {
		Deleted int64 `json:"deleted"`
	}
	_ = json.Unmarshal(rrClearA.Body.Bytes(), &clearOut)
	if clearOut.Deleted != 1 {
		t.Fatalf("expected 1 read deleted in srcA, got %d", clearOut.Deleted)
	}

	// Batch delete remaining n3 and n4
	rrBatchDel := doJSON(t, h, http.MethodPost, "/api/v1/notifications/batch", "master-key", map[string]any{
		"action": "delete", "ids": []string{n3, n4},
	})
	if rrBatchDel.Code != http.StatusOK {
		t.Fatalf("batch delete got %d", rrBatchDel.Code)
	}

	// Verify sync events emitted in order
	rrSync := doJSON(t, h, http.MethodGet, "/api/v1/sync?since_seq=0", "master-key", nil)
	var syncOut struct {
		Events []struct {
			EventType string `json:"event_type"`
		} `json:"events"`
	}
	_ = json.Unmarshal(rrSync.Body.Bytes(), &syncOut)
	seen := map[string]bool{}
	for _, ev := range syncOut.Events {
		seen[ev.EventType] = true
	}
	for _, want := range []string{"notification.deleted", "notifications.batch_updated", "notifications.cleared_read", "notifications.batch_deleted"} {
		if !seen[want] {
			t.Fatalf("missing sync event %q in %+v", want, seen)
		}
	}

	// Triggering an alarm via REST returns notification: null and state: ringing
	past := time.Now().UTC().Add(-time.Minute)
	rrAlarm := doJSON(t, h, http.MethodPost, "/api/v1/schedules", "master-key", map[string]any{
		"kind": "alarm", "title": "Wake", "schedule_type": "once", "fire_at": past,
	})
	var created struct {
		Schedule struct{ ID string } `json:"schedule"`
	}
	_ = json.Unmarshal(rrAlarm.Body.Bytes(), &created)
	rrTrig := doJSON(t, h, http.MethodPost, "/api/v1/schedules/"+created.Schedule.ID+"/triggered", "master-key", map[string]any{})
	if rrTrig.Code != http.StatusOK {
		t.Fatalf("alarm triggered got %d: %s", rrTrig.Code, rrTrig.Body.String())
	}
	var trigOut map[string]any
	_ = json.Unmarshal(rrTrig.Body.Bytes(), &trigOut)
	if trigOut["notification"] != nil {
		t.Fatalf("expected notification=nil for alarm trigger, got %+v", trigOut["notification"])
	}
	scMap := trigOut["schedule"].(map[string]any)
	if scMap["state"] != "ringing" {
		t.Fatalf("expected schedule state=ringing, got %+v", scMap["state"])
	}
}
