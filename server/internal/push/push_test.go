package push

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"dinglin/server/internal/store"

	"github.com/coder/websocket"
)

func generateTestServiceAccount(t *testing.T, tokenURI string) []byte {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("gen rsa key: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal pkcs8: %v", err)
	}
	pemBlock := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	raw, _ := json.Marshal(map[string]string{
		"project_id":   "dinglin-test",
		"client_email": "fcm@dinglin-test.iam.gserviceaccount.com",
		"private_key":  string(pemBlock),
		"token_uri":    tokenURI,
	})
	return raw
}

func TestFCMTransportAndUnregisteredCleanup(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "push.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer st.Close()
	if err := st.Migrate(context.Background()); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	var returnUnregistered atomic.Bool
	var oauthCalls atomic.Int32
	var gotPriority string

	mockSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/token":
			oauthCalls.Add(1)
			if err := r.ParseForm(); err != nil || r.FormValue("assertion") == "" {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"access_token": "mock-access-token",
				"expires_in":   3600,
			})
		case "/v1/projects/dinglin-test/messages:send":
			if r.Header.Get("Authorization") != "Bearer mock-access-token" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			var body struct {
				Message struct {
					Token   string            `json:"token"`
					Android map[string]string `json:"android"`
					Data    map[string]string `json:"data"`
				} `json:"message"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			gotPriority = body.Message.Android["priority"]
			if returnUnregistered.Load() {
				w.WriteHeader(http.StatusNotFound)
				_, _ = w.Write([]byte(`{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}`))
				return
			}
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"name":"projects/dinglin-test/messages/1"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer mockSrv.Close()

	creds := generateTestServiceAccount(t, mockSrv.URL+"/token")
	fcm, err := NewFCMTransportFromJSON(creds, mockSrv.URL, mockSrv.Client())
	if err != nil {
		t.Fatalf("new fcm: %v", err)
	}

	now := time.Now().UTC().Unix()
	_, err = st.DB.Exec(`
		INSERT INTO devices (id, name, platform, token_hash, fcm_token, has_gms, push_mode, created_at)
		VALUES ('d1', 'Pixel', 'android', 'h1', 'fcm-tok-1', 1, 'fcm', ?)`, now)
	if err != nil {
		t.Fatalf("insert device: %v", err)
	}

	hub := NewWSHub(st)
	disp := NewDispatcher(st, hub, fcm)

	ch, err := disp.SendToDevice(context.Background(), "d1", EventMessage{
		Seq: 1, EventType: "notification.created", EntityID: "n1", Priority: "critical", Title: "Alert",
	})
	if err != nil || ch != "fcm" {
		t.Fatalf("expected fcm delivery, got ch=%q err=%v", ch, err)
	}
	if gotPriority != "HIGH" {
		t.Fatalf("expected android priority HIGH, got %q", gotPriority)
	}

	// Second call reuses cached OAuth token and clears invalid token on UNREGISTERED
	returnUnregistered.Store(true)
	_, err = disp.SendToDevice(context.Background(), "d1", EventMessage{
		Seq: 2, EventType: "notification.created", EntityID: "n2", Priority: "normal", Title: "Test",
	})
	if err == nil {
		t.Fatalf("expected error on UNREGISTERED")
	}
	if oauthCalls.Load() != 1 {
		t.Fatalf("expected cached oauth token (1 call), got %d", oauthCalls.Load())
	}

	var fcmTok, pushMode string
	_ = st.DB.QueryRow(`SELECT fcm_token, push_mode FROM devices WHERE id = 'd1'`).Scan(&fcmTok, &pushMode)
	if fcmTok != "" || pushMode != "ws" {
		t.Fatalf("expected cleared fcm_token and push_mode=ws, got token=%q mode=%q", fcmTok, pushMode)
	}

	// Device explicitly configured as push_mode='ws' must skip FCM even if fcm_token is present.
	_, err = st.DB.Exec(`
		INSERT INTO devices (id, name, platform, token_hash, fcm_token, has_gms, push_mode, created_at)
		VALUES ('d2', 'PixelWS', 'android', 'h2', 'fcm-tok-2', 1, 'ws', ?)`, now)
	if err != nil {
		t.Fatalf("insert d2: %v", err)
	}
	returnUnregistered.Store(false)
	ch, err = disp.SendToDevice(context.Background(), "d2", EventMessage{
		Seq: 3, EventType: "notification.created", EntityID: "n3", Priority: "normal", Title: "WS Only",
	})
	if err != nil || ch != "offline" {
		t.Fatalf("expected ws-only offline device to skip FCM and return offline, got ch=%q err=%v", ch, err)
	}
}

func TestWSHubConcurrentConnectAndBroadcast(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "ws.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer st.Close()
	if err := st.Migrate(context.Background()); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	hub := NewWSHub(st)
	wsSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hub.ServeWS(w, r, r.URL.Query().Get("dev"))
	}))
	defer wsSrv.Close()

	wsURL := "ws" + strings.TrimPrefix(wsSrv.URL, "http") + "?dev=dev1"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var wg sync.WaitGroup
	for range 3 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c, _, err := websocket.Dial(ctx, wsURL, nil)
			if err != nil {
				t.Errorf("dial: %v", err)
				return
			}
			defer c.Close(websocket.StatusNormalClosure, "")
			// Send ping and expect pong
			if err := c.Write(ctx, websocket.MessageText, []byte(`{"type":"ping"}`)); err != nil {
				t.Errorf("write ping: %v", err)
				return
			}
			_, raw, err := c.Read(ctx)
			if err != nil {
				t.Errorf("read pong: %v", err)
				return
			}
			if !strings.Contains(string(raw), `"type":"pong"`) {
				t.Errorf("expected pong, got %s", string(raw))
			}
		}()
	}
	wg.Wait()
}
