package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"dinglin/server/internal/auth"
	"dinglin/server/internal/domain"
	"dinglin/server/internal/notify"
)

func (s *Server) RegisterNotificationRoutes(notifySvc *notify.Service) {
	s.RegisterRoutes(func(mux *http.ServeMux) {
		mux.Handle("POST /api/v1/notify", s.auth.RequireSource(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleNotify(w, r, notifySvc)
		})))
		mux.HandleFunc("POST /api/v1/webhook/{slug}", func(w http.ResponseWriter, r *http.Request) {
			s.handleWebhook(w, r, notifySvc)
		})
		mux.Handle("GET /api/v1/notifications", s.auth.RequireOwner(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleListNotifications(w, r, notifySvc)
		})))
		mux.Handle("POST /api/v1/notifications/read-all", s.auth.RequireOwner(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleMarkAllRead(w, r, notifySvc)
		})))
		mux.Handle("DELETE /api/v1/notifications/{id}", s.auth.RequireOwner(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleDeleteNotification(w, r, notifySvc)
		})))
		mux.Handle("POST /api/v1/notifications/batch", s.auth.RequireOwner(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleBatchNotifications(w, r, notifySvc)
		})))
		mux.Handle("POST /api/v1/notifications/clear-read", s.auth.RequireOwner(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleClearReadNotifications(w, r, notifySvc)
		})))
	})
}

func (s *Server) handleNotify(w http.ResponseWriter, r *http.Request, notifySvc *notify.Service) {
	p, _ := auth.FromContext(r.Context())
	var req struct {
		Title          string               `json:"title"`
		Body           string               `json:"body"`
		Priority       string               `json:"priority"`
		Category       string               `json:"category"`
		Actions        []domain.QuickAction `json:"actions"`
		ExpiresAt      *time.Time           `json:"expires_at"`
		ExpiresInSec   int                  `json:"expires_in_sec"`
		CallbackURL    string               `json:"callback_url"`
		Metadata       map[string]any       `json:"metadata"`
		IdempotencyKey string               `json:"idempotency_key"`
	}
	if err := DecodeJSON(r, &req); err != nil {
		WriteError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	if hdrKey := strings.TrimSpace(r.Header.Get("Idempotency-Key")); hdrKey != "" {
		req.IdempotencyKey = hdrKey
	}

	srcID := p.Source.ID
	notif, dedup, err := notifySvc.Create(r.Context(), notify.CreateInput{
		SourceID:       &srcID,
		IdempotencyKey: req.IdempotencyKey,
		Priority:       req.Priority,
		Title:          req.Title,
		Body:           req.Body,
		Category:       req.Category,
		Actions:        req.Actions,
		Metadata:       req.Metadata,
		CallbackURL:    req.CallbackURL,
		ExpiresAt:      req.ExpiresAt,
		ExpiresInSec:   req.ExpiresInSec,
	})
	if err != nil {
		if errors.Is(err, notify.ErrValidation) {
			WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
			return
		}
		WriteError(w, http.StatusInternalServerError, "notify_error", err.Error())
		return
	}
	status := http.StatusCreated
	if dedup {
		status = http.StatusOK
	}
	WriteJSON(w, status, map[string]any{
		"notification": notif,
		"deduplicated": dedup,
	})
}

func (s *Server) handleWebhook(w http.ResponseWriter, r *http.Request, notifySvc *notify.Service) {
	slug := strings.TrimSpace(r.PathValue("slug"))
	tok := auth.ExtractToken(r, true)
	src, err := s.auth.AuthenticateSource(r.Context(), tok)
	if errors.Is(err, auth.ErrForbidden) {
		WriteError(w, http.StatusForbidden, "source_disabled", "source is disabled")
		return
	}
	if err != nil {
		WriteError(w, http.StatusUnauthorized, "unauthorized", "invalid or missing webhook token")
		return
	}
	if src.Slug != slug {
		WriteError(w, http.StatusForbidden, "slug_mismatch", "token does not match webhook slug")
		return
	}

	defer r.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		WriteError(w, http.StatusBadRequest, "read_error", err.Error())
		return
	}
	trimmed := strings.TrimSpace(string(raw))
	if trimmed == "" {
		WriteError(w, http.StatusBadRequest, "empty_body", "webhook body is empty")
		return
	}

	in := notify.CreateInput{
		SourceID:       &src.ID,
		IdempotencyKey: strings.TrimSpace(r.Header.Get("Idempotency-Key")),
		Priority:       domain.PriorityNormal,
	}

	if strings.HasPrefix(trimmed, "{") {
		var m map[string]any
		if err := json.Unmarshal(raw, &m); err == nil {
			in.Title = firstString(m, "title", "summary", "subject", "event")
			in.Body = firstString(m, "body", "message", "text", "description", "content")
			if in.Title == "" && in.Body != "" {
				in.Title = src.Name
			}
			if p := firstString(m, "priority", "severity", "level"); p != "" {
				in.Priority = normalizePriority(p)
			}
			in.Category = firstString(m, "category", "type")
			in.CallbackURL = firstString(m, "callback_url")
			if k := firstString(m, "idempotency_key"); k != "" && in.IdempotencyKey == "" {
				in.IdempotencyKey = k
			}
			if rawActions, ok := m["actions"]; ok {
				if ab, err := json.Marshal(rawActions); err == nil {
					_ = json.Unmarshal(ab, &in.Actions)
				}
			}
			if meta, ok := m["metadata"].(map[string]any); ok {
				in.Metadata = meta
			}
		}
	}
	if in.Title == "" {
		in.Title = src.Name
		in.Body = trimmed
	}

	notif, dedup, err := notifySvc.Create(r.Context(), in)
	if err != nil {
		WriteError(w, http.StatusBadRequest, "webhook_error", err.Error())
		return
	}
	status := http.StatusCreated
	if dedup {
		status = http.StatusOK
	}
	WriteJSON(w, status, map[string]any{
		"notification": notif,
		"deduplicated": dedup,
	})
}

func (s *Server) handleListNotifications(w http.ResponseWriter, r *http.Request, notifySvc *notify.Service) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	beforeSeq, _ := strconv.ParseInt(q.Get("before_seq"), 10, 64)
	includeExpired := q.Get("include_expired") == "true" || q.Get("include_expired") == "1"

	list, err := notifySvc.List(r.Context(), notify.ListFilter{
		Q:              strings.TrimSpace(q.Get("q")),
		SourceID:       strings.TrimSpace(q.Get("source_id")),
		Priority:       strings.TrimSpace(q.Get("priority")),
		Status:         strings.TrimSpace(q.Get("status")),
		IncludeExpired: includeExpired,
		Limit:          limit,
		BeforeSeq:      beforeSeq,
	})
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"notifications": list})
}

func (s *Server) handleMarkAllRead(w http.ResponseWriter, r *http.Request, notifySvc *notify.Service) {
	var req struct {
		SourceID string `json:"source_id"`
	}
	if err := DecodeJSON(r, &req); err != nil && err.Error() != "empty request body" {
		WriteError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	count, err := notifySvc.MarkAllRead(r.Context(), req.SourceID)
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"updated": count})
}

func (s *Server) handleDeleteNotification(w http.ResponseWriter, r *http.Request, notifySvc *notify.Service) {
	id := r.PathValue("id")
	if err := notifySvc.Delete(r.Context(), id); err != nil {
		if errors.Is(err, notify.ErrNotFound) {
			WriteError(w, http.StatusNotFound, "not_found", err.Error())
			return
		}
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"deleted": true, "id": id})
}

func (s *Server) handleBatchNotifications(w http.ResponseWriter, r *http.Request, notifySvc *notify.Service) {
	var req struct {
		Action string   `json:"action"`
		Ids    []string `json:"ids"`
	}
	if err := DecodeJSON(r, &req); err != nil {
		WriteError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	affected, err := notifySvc.BatchAction(r.Context(), req.Action, req.Ids)
	if err != nil {
		if errors.Is(err, notify.ErrValidation) {
			WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
			return
		}
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{
		"action":   strings.ToLower(strings.TrimSpace(req.Action)),
		"affected": affected,
	})
}

func (s *Server) handleClearReadNotifications(w http.ResponseWriter, r *http.Request, notifySvc *notify.Service) {
	var req struct {
		SourceID string `json:"source_id"`
	}
	if err := DecodeJSON(r, &req); err != nil && err.Error() != "empty request body" {
		WriteError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	deleted, err := notifySvc.ClearRead(r.Context(), req.SourceID)
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"deleted": deleted})
}

func firstString(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k].(string); ok && strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func normalizePriority(v string) string {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "critical", "urgent", "high", "error", "fatal", "p0":
		return domain.PriorityCritical
	case "silent", "low", "debug", "info":
		return domain.PrioritySilent
	default:
		return domain.PriorityNormal
	}
}
