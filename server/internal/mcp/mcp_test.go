package mcp

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"dinglin/server/internal/auth"
	"dinglin/server/internal/callback"
	"dinglin/server/internal/domain"
	"dinglin/server/internal/notify"
	"dinglin/server/internal/schedule"
	"dinglin/server/internal/store"
)

func setupMCPTest(t *testing.T) (*httptest.Server, *store.Store, *callback.Service, *schedule.Service, string, string, string) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "mcp.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	if err := st.Migrate(context.Background()); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	authenticator := auth.New(st, "master-secret")
	notifySvc := notify.NewService(st, nil)
	scheduleSvc := schedule.NewService(st, notifySvc, nil)
	callbackSvc := callback.NewService(st, notifySvc, scheduleSvc, nil, 30)
	mcpSrv := NewServer(authenticator, notifySvc, scheduleSvc, callbackSvc)

	mux := http.NewServeMux()
	mcpSrv.RegisterRoutes(mux)
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)

	insertSource := func(slug, kind string, enabled bool) string {
		tok, prefix, hash, _ := auth.GenerateToken("src_")
		now := time.Now().UTC().Unix()
		_, err := st.DB.Exec(`
			INSERT INTO sources (id, slug, name, kind, color, token_hash, token_prefix, callback_url, callback_secret, enabled, created_at, updated_at)
			VALUES (?, ?, ?, ?, '#007AFF', ?, ?, '', '', ?, ?, ?)`,
			domain.NewID(), slug, slug, kind, hash, prefix, store.BoolToInt(enabled), now, now,
		)
		if err != nil {
			t.Fatalf("insert source %s: %v", slug, err)
		}
		return tok
	}

	agentAToken := insertSource("agent-a", domain.SourceKindAgent, true)
	agentBToken := insertSource("agent-b", domain.SourceKindAgent, true)
	webhookToken := insertSource("wh-source", domain.SourceKindWebhook, true)
	return ts, st, callbackSvc, scheduleSvc, agentAToken, agentBToken, webhookToken
}

func doMCP(t *testing.T, url, token, sessionID string, body any) *http.Response {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, url+"/mcp", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if sessionID != "" {
		req.Header.Set(SessionHeader, sessionID)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("post /mcp: %v", err)
	}
	return resp
}

func TestMCPStreamableHTTPAndIsolation(t *testing.T) {
	ts, _, callbackSvc, scheduleSvc, tokA, tokB, tokWH := setupMCPTest(t)

	// 1. Auth & kind checks
	resp := doMCP(t, ts.URL, "bad-token", "", map[string]any{"jsonrpc": "2.0", "id": 1, "method": "initialize"})
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 for bad token, got %d", resp.StatusCode)
	}
	_ = resp.Body.Close()

	resp = doMCP(t, ts.URL, tokWH, "", map[string]any{"jsonrpc": "2.0", "id": 1, "method": "initialize"})
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected 403 for webhook source, got %d", resp.StatusCode)
	}
	_ = resp.Body.Close()

	// 2. Initialize Agent A & Agent B
	initResp := doMCP(t, ts.URL, tokA, "", map[string]any{"jsonrpc": "2.0", "id": 1, "method": "initialize"})
	if initResp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 on initialize, got %d", initResp.StatusCode)
	}
	sidA := initResp.Header.Get(SessionHeader)
	if sidA == "" {
		t.Fatalf("expected Mcp-Session-Id header")
	}
	_ = initResp.Body.Close()

	initRespB := doMCP(t, ts.URL, tokB, "", map[string]any{"jsonrpc": "2.0", "id": 1, "method": "initialize"})
	sidB := initRespB.Header.Get(SessionHeader)
	_ = initRespB.Body.Close()

	// 3. notifications/initialized -> 202 Accepted with empty body
	notifInit := doMCP(t, ts.URL, tokA, sidA, map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})
	if notifInit.StatusCode != http.StatusAccepted {
		t.Fatalf("expected 202 for notifications/initialized, got %d", notifInit.StatusCode)
	}
	_ = notifInit.Body.Close()

	// 4. tools/list -> 7 tools
	listResp := doMCP(t, ts.URL, tokA, sidA, map[string]any{"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
	var listBody struct {
		Result struct {
			Tools []map[string]any `json:"tools"`
		} `json:"result"`
	}
	_ = json.NewDecoder(listResp.Body).Decode(&listBody)
	_ = listResp.Body.Close()
	if len(listBody.Result.Tools) != 7 {
		t.Fatalf("expected 7 tools, got %d", len(listBody.Result.Tools))
	}

	// 5. Agent A sends notification & gets receipts
	sendResp := doMCP(t, ts.URL, tokA, sidA, map[string]any{
		"jsonrpc": "2.0",
		"id":      3,
		"method":  "tools/call",
		"params": map[string]any{
			"name": "send_notification",
			"arguments": map[string]any{
				"title":    "Deploy ready",
				"body":     "v1.0.0 built",
				"priority": "critical",
			},
		},
	})
	var sendRPC struct {
		Result struct {
			Content []struct {
				Text string `json:"text"`
			} `json:"content"`
			IsError bool `json:"isError"`
		} `json:"result"`
	}
	_ = json.NewDecoder(sendResp.Body).Decode(&sendRPC)
	_ = sendResp.Body.Close()
	if sendRPC.Result.IsError || len(sendRPC.Result.Content) == 0 {
		t.Fatalf("send_notification failed: %+v", sendRPC)
	}
	var sendPayload struct {
		Notification domain.Notification `json:"notification"`
	}
	_ = json.Unmarshal([]byte(sendRPC.Result.Content[0].Text), &sendPayload)
	if sendPayload.Notification.ID == "" {
		t.Fatalf("missing notification id")
	}

	// Submit receipt on notification
	if _, _, err := callbackSvc.SubmitReceipt(context.Background(), callback.ReceiptInput{
		NotificationID: sendPayload.Notification.ID,
		ActionID:       "ack",
	}); err != nil {
		t.Fatalf("submit receipt: %v", err)
	}

	// Agent B tries to read Agent A's receipts -> isError: true
	crossReceipt := doMCP(t, ts.URL, tokB, sidB, map[string]any{
		"jsonrpc": "2.0",
		"id":      4,
		"method":  "tools/call",
		"params": map[string]any{
			"name":      "get_notification_receipts",
			"arguments": map[string]any{"notification_id": sendPayload.Notification.ID},
		},
	})
	var crossRes struct {
		Result struct {
			IsError bool `json:"isError"`
		} `json:"result"`
	}
	_ = json.NewDecoder(crossReceipt.Body).Decode(&crossRes)
	_ = crossReceipt.Body.Close()
	if !crossRes.Result.IsError {
		t.Fatalf("expected Agent B to be denied access to Agent A receipts")
	}

	// 6. Owner creates a schedule (source_id = NULL) & Agent A creates a schedule
	ownerSched, err := scheduleSvc.Create(context.Background(), schedule.CreateInput{
		Kind:         domain.ScheduleKindAlarm,
		Title:        "Owner Alarm",
		ScheduleType: domain.ScheduleTypeCron,
		CronExpr:     "0 8 * * 1-5",
		Timezone:     "UTC",
	})
	if err != nil {
		t.Fatalf("owner create schedule: %v", err)
	}

	// Agent A tries to delete owner's schedule -> isError: true
	delOwner := doMCP(t, ts.URL, tokA, sidA, map[string]any{
		"jsonrpc": "2.0",
		"id":      5,
		"method":  "tools/call",
		"params": map[string]any{
			"name":      "delete_schedule",
			"arguments": map[string]any{"id": ownerSched.ID},
		},
	})
	var delOwnerRes struct {
		Result struct {
			IsError bool `json:"isError"`
		} `json:"result"`
	}
	_ = json.NewDecoder(delOwner.Body).Decode(&delOwnerRes)
	_ = delOwner.Body.Close()
	if !delOwnerRes.Result.IsError {
		t.Fatalf("expected Agent A to be denied deleting owner schedule")
	}

	// Agent A creates, updates, and deletes its own schedule
	createSchedResp := doMCP(t, ts.URL, tokA, sidA, map[string]any{
		"jsonrpc": "2.0",
		"id":      6,
		"method":  "tools/call",
		"params": map[string]any{
			"name": "create_schedule",
			"arguments": map[string]any{
				"kind":          "alarm",
				"title":         "Agent Standup",
				"schedule_type": "cron",
				"cron_expr":     "30 9 * * 1-5",
				"timezone":      "Asia/Shanghai",
			},
		},
	})
	var createSchedRPC struct {
		Result struct {
			Content []struct {
				Text string `json:"text"`
			} `json:"content"`
			IsError bool `json:"isError"`
		} `json:"result"`
	}
	_ = json.NewDecoder(createSchedResp.Body).Decode(&createSchedRPC)
	_ = createSchedResp.Body.Close()
	if createSchedRPC.Result.IsError {
		t.Fatalf("create_schedule failed: %+v", createSchedRPC)
	}
	var schedA domain.Schedule
	_ = json.Unmarshal([]byte(createSchedRPC.Result.Content[0].Text), &schedA)

	// Agent B cannot update Agent A's schedule
	updB := doMCP(t, ts.URL, tokB, sidB, map[string]any{
		"jsonrpc": "2.0",
		"id":      7,
		"method":  "tools/call",
		"params": map[string]any{
			"name":      "update_schedule",
			"arguments": map[string]any{"id": schedA.ID, "title": "Hijacked"},
		},
	})
	var updBRes struct {
		Result struct {
			IsError bool `json:"isError"`
		} `json:"result"`
	}
	_ = json.NewDecoder(updB.Body).Decode(&updBRes)
	_ = updB.Body.Close()
	if !updBRes.Result.IsError {
		t.Fatalf("expected Agent B to be denied updating Agent A schedule")
	}

	// DELETE /mcp invalidates session
	delReq, _ := http.NewRequest(http.MethodDelete, ts.URL+"/mcp", nil)
	delReq.Header.Set("Authorization", "Bearer "+tokA)
	delReq.Header.Set(SessionHeader, sidA)
	delResp, err := http.DefaultClient.Do(delReq)
	if err != nil {
		t.Fatalf("DELETE /mcp: %v", err)
	}
	_ = delResp.Body.Close()
	if delResp.StatusCode != http.StatusNoContent {
		t.Fatalf("expected 204 on DELETE /mcp, got %d", delResp.StatusCode)
	}

	// Reusing deleted session returns 404
	afterDel := doMCP(t, ts.URL, tokA, sidA, map[string]any{"jsonrpc": "2.0", "id": 8, "method": "ping"})
	if afterDel.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404 after session deletion, got %d", afterDel.StatusCode)
	}
	_ = afterDel.Body.Close()
}

func TestMCPStdioBridge(t *testing.T) {
	ts, _, _, _, tokA, _, _ := setupMCPTest(t)

	inputLines := strings.Join([]string{
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`,
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
		`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"send_notification","arguments":{"title":"Stdio Ping"}}}`,
	}, "\n") + "\n"

	var stdout, stderr bytes.Buffer
	err := RunStdio(
		context.Background(),
		[]string{"--server", ts.URL + "/mcp", "--token", tokA},
		strings.NewReader(inputLines),
		&stdout,
		&stderr,
	)
	if err != nil {
		t.Fatalf("RunStdio error: %v (stderr=%s)", err, stderr.String())
	}

	lines := strings.Split(strings.TrimSpace(stdout.String()), "\n")
	if len(lines) != 3 {
		t.Fatalf("expected exactly 3 stdout JSON-RPC responses (skipping 202), got %d:\n%s", len(lines), stdout.String())
	}
	if !strings.Contains(lines[0], `"protocolVersion"`) {
		t.Fatalf("line 0 missing protocolVersion: %s", lines[0])
	}
	if !strings.Contains(lines[1], `"send_notification"`) {
		t.Fatalf("line 1 missing tools/list: %s", lines[1])
	}
	if !strings.Contains(lines[2], "Stdio Ping") {
		t.Fatalf("line 2 missing send_notification result: %s", lines[2])
	}
}
