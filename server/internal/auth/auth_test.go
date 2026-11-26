package auth

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"dinglin/server/internal/store"
)

func TestAuthMiddlewares(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "auth.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer st.Close()
	if err := st.Migrate(context.Background()); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	srcPlain, srcPrefix, srcHash, err := GenerateToken("src_")
	if err != nil {
		t.Fatalf("gen src token: %v", err)
	}
	disabledPlain, disabledPrefix, disabledHash, err := GenerateToken("src_")
	if err != nil {
		t.Fatalf("gen disabled token: %v", err)
	}
	devPlain, _, devHash, err := GenerateToken("dev_")
	if err != nil {
		t.Fatalf("gen dev token: %v", err)
	}

	now := time.Now().UTC().Unix()
	_, err = st.DB.Exec(`
		INSERT INTO sources (id, slug, name, kind, token_hash, token_prefix, enabled, created_at, updated_at)
		VALUES ('s1', 'app1', 'App 1', 'webhook', ?, ?, 1, ?, ?),
		       ('s2', 'app2', 'App 2', 'agent', ?, ?, 0, ?, ?)`,
		srcHash, srcPrefix, now, now, disabledHash, disabledPrefix, now, now)
	if err != nil {
		t.Fatalf("insert sources: %v", err)
	}
	_, err = st.DB.Exec(`
		INSERT INTO devices (id, name, platform, token_hash, created_at)
		VALUES ('d1', 'Phone', 'android', ?, ?)`, devHash, now)
	if err != nil {
		t.Fatalf("insert device: %v", err)
	}

	a := New(st, "super-secret-master")
	okHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	ownerH := a.RequireOwner(okHandler)
	sourceH := a.RequireSource(okHandler)

	cases := []struct {
		name    string
		handler http.Handler
		token   string
		want    int
	}{
		{"owner missing", ownerH, "", http.StatusUnauthorized},
		{"owner master key", ownerH, "super-secret-master", http.StatusOK},
		{"owner device token", ownerH, devPlain, http.StatusOK},
		{"owner rejected source token", ownerH, srcPlain, http.StatusUnauthorized},
		{"source missing", sourceH, "", http.StatusUnauthorized},
		{"source valid", sourceH, srcPlain, http.StatusOK},
		{"source disabled", sourceH, disabledPlain, http.StatusForbidden},
		{"source rejected master", sourceH, "super-secret-master", http.StatusUnauthorized},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/", nil)
			if tc.token != "" {
				req.Header.Set("Authorization", "Bearer "+tc.token)
			}
			rr := httptest.NewRecorder()
			tc.handler.ServeHTTP(rr, req)
			if rr.Code != tc.want {
				t.Fatalf("got status %d, want %d", rr.Code, tc.want)
			}
		})
	}
}
