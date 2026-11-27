package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"dinglin/server/internal/api"
	"dinglin/server/internal/auth"
	"dinglin/server/internal/callback"
	"dinglin/server/internal/config"
	"dinglin/server/internal/domain"
	"dinglin/server/internal/mcp"
	"dinglin/server/internal/notify"
	"dinglin/server/internal/push"
	"dinglin/server/internal/schedule"
	"dinglin/server/internal/store"
)

type mockFCM struct {
	mu   sync.Mutex
	sent []string
}

func (m *mockFCM) Send(_ context.Context, device domain.Device, msg push.EventMessage) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sent = append(m.sent, device.ID+":"+msg.Title)
	return nil
}

func (m *mockFCM) Count() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.sent)
}

func doJSON(t *testing.T, method, url, token string, body any) (*http.Response, []byte) {
	t.Helper()
	var r io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, url, r)
	if err != nil {
		t.Fatalf("new req: %v", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp, data
}

func TestEndToEndFullLoop(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(filepath.Join(t.TempDir(), "e2e.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()
	if err := st.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	const masterKey = "e2e-master-key-123"
	fcmMock := &mockFCM{}
	hub := push.NewWSHub(st)
	dispatcher := push.NewDispatcher(st, hub, fcmMock)
	notifySvc := notify.NewService(st, dispatcher)
	scheduleSvc := schedule.NewService(st, notifySvc, dispatcher)
	callbackSvc := callback.NewService(st, notifySvc, scheduleSvc, dispatcher, 30)
	authenticator := auth.New(st, masterKey)

	srv := api.NewServer(config.Config{MasterKey: masterKey, RetentionDays: 30}, st, authenticator)
	srv.RegisterNotificationRoutes(notifySvc)
	srv.RegisterSyncAndPushRoutes(hub, dispatcher)
	srv.RegisterScheduleRoutes(scheduleSvc)
	srv.RegisterReceiptRoutes(callbackSvc, notifySvc)
	mcpSrv := mcp.NewServer(authenticator, notifySvc, scheduleSvc, callbackSvc)
	srv.RegisterRoutes(mcpSrv.RegisterRoutes)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	// Mock Webhook receiver: first call 500, second call 200 with HMAC verification
	var whAttempts atomic.Int32
	var whVerified atomic.Bool
	var whSecret string
	whReceiver := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		tsHdr := r.Header.Get("X-Dinglin-Timestamp")
		sigHdr := r.Header.Get("X-Dinglin-Signature")
		if sigHdr == callback.ComputeSignature(whSecret, tsHdr, body) {
			whVerified.Store(true)
		}
		if whAttempts.Add(1) == 1 {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer whReceiver.Close()

	// === Scenario 1: Master key creates Source A (agent) & Source B (webhook) + Pairing ===
	resp, raw := doJSON(t, http.MethodPost, ts.URL+"/api/v1/sources", masterKey, map[string]any{
		"name":         "Cloud Agent A",
		"slug":         "cloud-agent-a",
		"kind":         "agent",
		"callback_url": whReceiver.URL,
	})
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create source A: %d %s", resp.StatusCode, raw)
	}
	var srcAResp struct {
		Source         domain.Source `json:"source"`
		Token          string        `json:"token"`
		CallbackSecret string        `json:"callback_secret"`
	}
	_ = json.Unmarshal(raw, &srcAResp)
	whSecret = srcAResp.CallbackSecret

	resp, raw = doJSON(t, http.MethodPost, ts.URL+"/api/v1/sources", masterKey, map[string]any{
		"name": "CI Webhook B",
		"slug": "ci-webhook-b",
		"kind": "webhook",
	})
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create source B: %d %s", resp.StatusCode, raw)
	}
	var srcBResp struct {
		Source domain.Source `json:"source"`
		Token  string        `json:"token"`
	}
	_ = json.Unmarshal(raw, &srcBResp)

	// Pairing code -> Pair Android device (with FCM) & Web device
	resp, raw = doJSON(t, http.MethodPost, ts.URL+"/api/v1/pairing-codes", masterKey, nil)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create pairing code: %d %s", resp.StatusCode, raw)
	}
	var pairCode struct {
		Code string `json:"code"`
	}
	_ = json.Unmarshal(raw, &pairCode)

	resp, raw = doJSON(t, http.MethodPost, ts.URL+"/api/v1/devices/pair", "", map[string]any{
		"code":     pairCode.Code,
		"name":     "Pixel 9",
		"platform": "android",
		"has_gms":  true,
	})
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("pair android: %d %s", resp.StatusCode, raw)
	}
	var devAndroid struct {
		Device domain.Device `json:"device"`
		Token  string        `json:"device_token"`
	}
	_ = json.Unmarshal(raw, &devAndroid)

	resp, raw = doJSON(t, http.MethodPost, ts.URL+"/api/v1/devices/"+devAndroid.Device.ID+"/fcm-token", devAndroid.Token, map[string]any{
		"fcm_token": "fcm-tok-pixel9",
		"has_gms":   true,
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("register fcm token: %d %s", resp.StatusCode, raw)
	}

	// === Scenario 2: HTTP & Webhook idempotency + expiry filtering + search ===
	resp, raw = doJSON(t, http.MethodPost, ts.URL+"/api/v1/webhook/"+srcBResp.Source.Slug, srcBResp.Token, map[string]any{
		"title":           "Build #42 Failed",
		"body":            "unit test timeout in auth",
		"priority":        "critical",
		"idempotency_key": "build-42",
	})
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("webhook 1: %d %s", resp.StatusCode, raw)
	}
	var n1 struct {
		Notification domain.Notification `json:"notification"`
		Deduplicated bool                `json:"deduplicated"`
	}
	_ = json.Unmarshal(raw, &n1)

	resp, raw = doJSON(t, http.MethodPost, ts.URL+"/api/v1/webhook/"+srcBResp.Source.Slug, srcBResp.Token, map[string]any{
		"title":           "Build #42 Failed",
		"body":            "duplicate",
		"idempotency_key": "build-42",
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("webhook dedup expected 200, got %d", resp.StatusCode)
	}
	var n1Dup struct {
		Notification domain.Notification `json:"notification"`
		Deduplicated bool                `json:"deduplicated"`
	}
	_ = json.Unmarshal(raw, &n1Dup)
	if !n1Dup.Deduplicated || n1Dup.Notification.ID != n1.Notification.ID {
		t.Fatalf("expected deduplicated notification")
	}

	// Expired notification filtered out by default
	past := time.Now().UTC().Add(-1 * time.Hour)
	_, _, _ = notifySvc.Create(ctx, notify.CreateInput{
		SourceID:  &srcBResp.Source.ID,
		Title:     "Old Expired Alert",
		ExpiresAt: &past,
	})
	resp, raw = doJSON(t, http.MethodGet, ts.URL+"/api/v1/notifications?q=Build", devAndroid.Token, nil)
	var listNotifs struct {
		Notifications []domain.Notification `json:"notifications"`
	}
	_ = json.Unmarshal(raw, &listNotifs)
	if len(listNotifs.Notifications) != 1 || listNotifs.Notifications[0].ID != n1.Notification.ID {
		t.Fatalf("expected 1 search result, got %+v", listNotifs.Notifications)
	}

	// === Scenario 3: WS real-time delivery + offline catch-up + FCM fallback ===
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/api/v1/ws?token=" + devAndroid.Token
	wsConn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("ws dial: %v", err)
	}

	// Send notification while WS online
	resp, raw = doJSON(t, http.MethodPost, ts.URL+"/api/v1/notify", srcAResp.Token, map[string]any{
		"title":    "Online Ping",
		"priority": "normal",
		"actions": []map[string]any{
			{"id": "approve", "label": "批准"},
		},
	})
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("send online notif: %d %s", resp.StatusCode, raw)
	}
	var onlineNotif struct {
		Notification domain.Notification `json:"notification"`
	}
	_ = json.Unmarshal(raw, &onlineNotif)

	readCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	var wsFrame map[string]any
	if err := wsjson.Read(readCtx, wsConn, &wsFrame); err != nil {
		t.Fatalf("ws read: %v", err)
	}
	cancel()
	if wsFrame["type"] != "event" {
		t.Fatalf("expected ws event frame, got %+v", wsFrame)
	}
	lastSeq := onlineNotif.Notification.Seq

	// Disconnect WS -> offline notification triggers FCM & accumulates for /sync
	_ = wsConn.Close(websocket.StatusNormalClosure, "bye")
	time.Sleep(50 * time.Millisecond)

	_, _, err = notifySvc.Create(ctx, notify.CreateInput{
		SourceID: &srcAResp.Source.ID,
		Title:    "Offline Critical Alert",
		Priority: domain.PriorityCritical,
	})
	if err != nil {
		t.Fatalf("create offline notif: %v", err)
	}
	if fcmMock.Count() == 0 {
		t.Fatalf("expected offline FCM fallback to fire")
	}

	resp, raw = doJSON(t, http.MethodGet, ts.URL+"/api/v1/sync?since_seq="+jsonNumber(lastSeq), devAndroid.Token, nil)
	var syncRes struct {
		Events []domain.SyncEvent `json:"events"`
	}
	_ = json.Unmarshal(raw, &syncRes)
	if len(syncRes.Events) == 0 {
		t.Fatalf("expected incremental sync events after disconnect")
	}

	// === Scenario 4: Schedules (alarm/countdown), snooze inheriting actions, /triggered dedup ===
	// Snooze onlineNotif (which has action "approve") -> creates snooze schedule with source_notification_id
	resp, raw = doJSON(t, http.MethodPost, ts.URL+"/api/v1/notifications/"+onlineNotif.Notification.ID+"/receipt", devAndroid.Token, map[string]any{
		"action_id":      "snooze",
		"snooze_minutes": 5,
	})
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("snooze receipt: %d %s", resp.StatusCode, raw)
	}
	scheds, _ := scheduleSvc.List(ctx, schedule.ListFilter{})
	if len(scheds) != 1 || scheds[0].SourceNotificationID == nil {
		t.Fatalf("expected 1 snooze schedule referencing source_notification_id, got %+v", scheds)
	}
	// Fire due schedule via /triggered twice -> second is deduplicated, created notification inherits actions
	occ := "sched:" + scheds[0].ID + ":test-occ"
	resp, raw = doJSON(t, http.MethodPost, ts.URL+"/api/v1/schedules/"+scheds[0].ID+"/triggered", devAndroid.Token, map[string]any{
		"occurrence_key": occ,
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("triggered 1: %d %s", resp.StatusCode, raw)
	}
	var trig1 struct {
		Notification domain.Notification `json:"notification"`
		Deduplicated bool                `json:"deduplicated"`
	}
	_ = json.Unmarshal(raw, &trig1)
	if trig1.Deduplicated || len(trig1.Notification.Actions) != 1 || trig1.Notification.Actions[0].ID != "approve" {
		t.Fatalf("expected snoozed notification to inherit actions, got %+v", trig1)
	}
	resp, raw = doJSON(t, http.MethodPost, ts.URL+"/api/v1/schedules/"+scheds[0].ID+"/triggered", devAndroid.Token, map[string]any{
		"occurrence_key": occ,
	})
	var trig2 struct {
		Deduplicated bool `json:"deduplicated"`
	}
	_ = json.Unmarshal(raw, &trig2)
	if !trig2.Deduplicated {
		t.Fatalf("expected second /triggered with same occurrence_key to be deduplicated")
	}

	// === Scenario 5: Quick receipt -> HMAC webhook delivery + retry ===
	// ProcessOnce #1 hits 500 -> schedules retry (+5s); ProcessOnce #2 at +10s hits 200
	now := time.Now().UTC()
	if _, err := callbackSvc.ProcessOnce(ctx, now.Add(1*time.Second)); err != nil {
		t.Fatalf("callback process 1: %v", err)
	}
	if _, err := callbackSvc.ProcessOnce(ctx, now.Add(15*time.Second)); err != nil {
		t.Fatalf("callback process 2: %v", err)
	}
	if whAttempts.Load() < 2 || !whVerified.Load() {
		t.Fatalf("expected webhook retry & valid HMAC signature, attempts=%d verified=%v", whAttempts.Load(), whVerified.Load())
	}

	// === Scenario 6: Cloud Agent via /mcp handshake, critical alert, cron alarm, read receipts ===
	initReq, _ := http.NewRequest(http.MethodPost, ts.URL+"/mcp", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"initialize"}`))
	initReq.Header.Set("Content-Type", "application/json")
	initReq.Header.Set("Authorization", "Bearer "+srcAResp.Token)
	initResp, err := http.DefaultClient.Do(initReq)
	if err != nil {
		t.Fatalf("mcp init: %v", err)
	}
	sid := initResp.Header.Get(mcp.SessionHeader)
	_ = initResp.Body.Close()
	if sid == "" {
		t.Fatalf("missing Mcp-Session-Id")
	}

	callMCP := func(body string) []byte {
		req, _ := http.NewRequest(http.MethodPost, ts.URL+"/mcp", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+srcAResp.Token)
		req.Header.Set(mcp.SessionHeader, sid)
		r, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("mcp call: %v", err)
		}
		defer r.Body.Close()
		b, _ := io.ReadAll(r.Body)
		return b
	}

	// Create cron alarm via MCP
	cronRaw := callMCP(`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_schedule","arguments":{"kind":"alarm","title":"MCP Morning","schedule_type":"cron","cron_expr":"0 7 * * 1-5","timezone":"Asia/Shanghai"}}}`)
	if !strings.Contains(string(cronRaw), "MCP Morning") {
		t.Fatalf("mcp create_schedule failed: %s", cronRaw)
	}

	// Read receipts of onlineNotif via MCP
	recRaw := callMCP(`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_notification_receipts","arguments":{"notification_id":"` + onlineNotif.Notification.ID + `"}}}`)
	if !strings.Contains(string(recRaw), "snooze") {
		t.Fatalf("mcp get_notification_receipts failed: %s", recRaw)
	}

	// === Scenario 7: Alarm ringing isolation & notification batch/delete/clear-read ===
	pastAlarm := time.Now().UTC().Add(-time.Minute)
	resp, raw = doJSON(t, http.MethodPost, ts.URL+"/api/v1/schedules", devAndroid.Token, map[string]any{
		"kind": "alarm", "title": "E2E Alarm", "schedule_type": "once", "fire_at": pastAlarm,
	})
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create alarm: %d %s", resp.StatusCode, raw)
	}
	var e2eAlarm struct {
		Schedule domain.Schedule `json:"schedule"`
	}
	_ = json.Unmarshal(raw, &e2eAlarm)

	notifsBefore, _ := notifySvc.List(ctx, notify.ListFilter{IncludeExpired: true})
	resp, raw = doJSON(t, http.MethodPost, ts.URL+"/api/v1/schedules/"+e2eAlarm.Schedule.ID+"/triggered", devAndroid.Token, map[string]any{})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("trigger e2e alarm: %d %s", resp.StatusCode, raw)
	}
	notifsAfter, _ := notifySvc.List(ctx, notify.ListFilter{IncludeExpired: true})
	if len(notifsAfter) != len(notifsBefore) {
		t.Fatalf("alarm trigger must not create notifications: before=%d after=%d", len(notifsBefore), len(notifsAfter))
	}
	resp, _ = doJSON(t, http.MethodPost, ts.URL+"/api/v1/schedules/"+e2eAlarm.Schedule.ID+"/dismiss", devAndroid.Token, map[string]any{})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("dismiss e2e alarm: %d", resp.StatusCode)
	}

	// Batch read & delete via REST
	resp, _ = doJSON(t, http.MethodPost, ts.URL+"/api/v1/notifications/batch", devAndroid.Token, map[string]any{
		"action": "read",
		"ids":    []string{n1.Notification.ID},
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("e2e batch read: %d", resp.StatusCode)
	}
	resp, _ = doJSON(t, http.MethodDelete, ts.URL+"/api/v1/notifications/"+n1.Notification.ID, devAndroid.Token, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("e2e delete notif: %d", resp.StatusCode)
	}
}

func jsonNumber(v int64) string {
	b, _ := json.Marshal(v)
	return string(b)
}
