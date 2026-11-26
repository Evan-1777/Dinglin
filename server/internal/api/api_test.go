package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"dinglin/server/internal/auth"
	"dinglin/server/internal/config"
	"dinglin/server/internal/store"
)

func setupTestAPI(t *testing.T) (*Server, http.Handler) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "api.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	if err := st.Migrate(context.Background()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	cfg := config.Config{MasterKey: "test-master-key", RetentionDays: 30}
	authenticator := auth.New(st, cfg.MasterKey)
	srv := NewServer(cfg, st, authenticator)
	return srv, srv.Handler()
}

func doJSON(t *testing.T, h http.Handler, method, path, token string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encode body: %v", err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	return rr
}

func TestSourcesDevicesPairingAndSettings(t *testing.T) {
	_, h := setupTestAPI(t)

	// Health check
	rr := doJSON(t, h, http.MethodGet, "/healthz", "", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("healthz got %d", rr.Code)
	}

	// Create source
	rr = doJSON(t, h, http.MethodPost, "/api/v1/sources", "test-master-key", map[string]any{
		"slug": "vps-monitor",
		"name": "VPS Monitor",
		"kind": "webhook",
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("create source got %d: %s", rr.Code, rr.Body.String())
	}
	var createResp struct {
		Source struct {
			ID          string `json:"id"`
			TokenPrefix string `json:"token_prefix"`
		} `json:"source"`
		Token          string `json:"token"`
		CallbackSecret string `json:"callback_secret"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &createResp); err != nil {
		t.Fatalf("decode create source: %v", err)
	}
	if createResp.Token == "" || createResp.CallbackSecret == "" {
		t.Fatalf("expected plaintext token and callback_secret")
	}

	// List sources must not leak plaintext token
	rr = doJSON(t, h, http.MethodGet, "/api/v1/sources", "test-master-key", nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("list sources got %d", rr.Code)
	}
	if bytes.Contains(rr.Body.Bytes(), []byte(createResp.Token)) {
		t.Fatalf("list sources leaked plaintext token")
	}

	// Issue pairing code & pair device (single-use)
	rr = doJSON(t, h, http.MethodPost, "/api/v1/pairing-codes", "test-master-key", nil)
	if rr.Code != http.StatusCreated {
		t.Fatalf("issue pairing code got %d", rr.Code)
	}
	var codeResp struct {
		Code string `json:"code"`
	}
	_ = json.Unmarshal(rr.Body.Bytes(), &codeResp)

	rr = doJSON(t, h, http.MethodPost, "/api/v1/devices/pair", "", map[string]any{
		"code":     codeResp.Code,
		"name":     "Pixel 9",
		"platform": "android",
		"has_gms":  true,
	})
	if rr.Code != http.StatusCreated {
		t.Fatalf("pair device got %d: %s", rr.Code, rr.Body.String())
	}
	var pairResp struct {
		DeviceID    string `json:"device_id"`
		DeviceToken string `json:"device_token"`
	}
	_ = json.Unmarshal(rr.Body.Bytes(), &pairResp)

	// Reusing pairing code must fail
	rr = doJSON(t, h, http.MethodPost, "/api/v1/devices/pair", "", map[string]any{
		"code":     codeResp.Code,
		"name":     "Pixel 9 Dup",
		"platform": "android",
	})
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 on reused pairing code, got %d", rr.Code)
	}

	// Paired device can access owner endpoints (settings)
	rr = doJSON(t, h, http.MethodPatch, "/api/v1/settings", pairResp.DeviceToken, map[string]any{
		"default_snooze_minutes": 15,
		"retention_days":         60,
	})
	if rr.Code != http.StatusOK {
		t.Fatalf("patch settings with device token got %d: %s", rr.Code, rr.Body.String())
	}
}
