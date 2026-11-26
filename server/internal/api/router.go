package api

import (
	"net/http"
	"os"
	"path/filepath"

	"dinglin/server/internal/auth"
	"dinglin/server/internal/config"
	"dinglin/server/internal/store"
)

// OnlineChecker reports whether a device currently holds an active WebSocket connection.
type OnlineChecker interface {
	IsOnline(deviceID string) bool
}

// Server wires HTTP routes for Dinglin.
type Server struct {
	cfg           config.Config
	store         *store.Store
	auth          *auth.Authenticator
	pairing       *PairingStore
	onlineChecker OnlineChecker
	extraRoutes   []func(*http.ServeMux)
}

func NewServer(cfg config.Config, st *store.Store, authenticator *auth.Authenticator) *Server {
	return &Server{
		cfg:     cfg,
		store:   st,
		auth:    authenticator,
		pairing: NewPairingStore(),
	}
}

func (s *Server) SetOnlineChecker(c OnlineChecker) {
	s.onlineChecker = c
}

// RegisterRoutes attaches additional route groups (Phase 2/3 engines).
func (s *Server) RegisterRoutes(fn func(*http.ServeMux)) {
	s.extraRoutes = append(s.extraRoutes, fn)
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		WriteJSON(w, http.StatusOK, map[string]any{
			"status":  "ok",
			"version": config.Version,
		})
	})

	// Sources (Owner)
	mux.Handle("GET /api/v1/sources", s.auth.RequireOwner(http.HandlerFunc(s.handleListSources)))
	mux.Handle("POST /api/v1/sources", s.auth.RequireOwner(http.HandlerFunc(s.handleCreateSource)))
	mux.Handle("PATCH /api/v1/sources/{id}", s.auth.RequireOwner(http.HandlerFunc(s.handleUpdateSource)))
	mux.Handle("POST /api/v1/sources/{id}/rotate-token", s.auth.RequireOwner(http.HandlerFunc(s.handleRotateSourceToken)))
	mux.Handle("DELETE /api/v1/sources/{id}", s.auth.RequireOwner(http.HandlerFunc(s.handleDeleteSource)))

	// Pairing & Devices
	mux.Handle("POST /api/v1/pairing-codes", s.auth.RequireOwner(http.HandlerFunc(s.handleCreatePairingCode)))
	mux.HandleFunc("POST /api/v1/devices/pair", s.handlePairDevice)
	mux.Handle("GET /api/v1/devices", s.auth.RequireOwner(http.HandlerFunc(s.handleListDevices)))
	mux.Handle("PATCH /api/v1/devices/{id}", s.auth.RequireOwner(http.HandlerFunc(s.handleUpdateDevice)))
	mux.Handle("DELETE /api/v1/devices/{id}", s.auth.RequireOwner(http.HandlerFunc(s.handleDeleteDevice)))
	mux.Handle("POST /api/v1/devices/{id}/fcm-token", s.auth.RequireOwner(http.HandlerFunc(s.handleUpdateFCMToken)))

	// Settings
	mux.Handle("GET /api/v1/settings", s.auth.RequireOwner(http.HandlerFunc(s.handleGetSettings)))
	mux.Handle("PATCH /api/v1/settings", s.auth.RequireOwner(http.HandlerFunc(s.handleUpdateSettings)))

	for _, fn := range s.extraRoutes {
		fn(mux)
	}

	if s.cfg.WebDistDir != "" {
		if info, err := os.Stat(s.cfg.WebDistDir); err == nil && info.IsDir() {
			fs := http.FileServer(http.Dir(s.cfg.WebDistDir))
			mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
				target := filepath.Join(s.cfg.WebDistDir, filepath.Clean(r.URL.Path))
				if _, err := os.Stat(target); os.IsNotExist(err) {
					http.ServeFile(w, r, filepath.Join(s.cfg.WebDistDir, "index.html"))
					return
				}
				fs.ServeHTTP(w, r)
			})
		}
	}

	return CORSMiddleware(mux)
}
