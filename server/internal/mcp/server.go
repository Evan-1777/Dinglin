package mcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"dinglin/server/internal/auth"
	"dinglin/server/internal/callback"
	"dinglin/server/internal/config"
	"dinglin/server/internal/domain"
	"dinglin/server/internal/notify"
	"dinglin/server/internal/schedule"
)

const (
	ProtocolVersion = "2025-03-26"
	SessionHeader   = "Mcp-Session-Id"
)

type Server struct {
	auth        *auth.Authenticator
	notifySvc   *notify.Service
	scheduleSvc *schedule.Service
	callbackSvc *callback.Service

	mu       sync.RWMutex
	sessions map[string]string // sessionID -> sourceID
}

func NewServer(authenticator *auth.Authenticator, notifySvc *notify.Service, scheduleSvc *schedule.Service, callbackSvc *callback.Service) *Server {
	return &Server{
		auth:        authenticator,
		notifySvc:   notifySvc,
		scheduleSvc: scheduleSvc,
		callbackSvc: callbackSvc,
		sessions:    make(map[string]string),
	}
}

func (s *Server) RegisterRoutes(mux *http.ServeMux) {
	mux.Handle("POST /mcp", s.auth.RequireSource(http.HandlerFunc(s.handlePost)))
	mux.Handle("DELETE /mcp", s.auth.RequireSource(http.HandlerFunc(s.handleDelete)))
}

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (s *Server) requireAgent(w http.ResponseWriter, r *http.Request) (*domain.Source, bool) {
	p, ok := auth.FromContext(r.Context())
	if !ok || p.Source == nil {
		writeHTTPError(w, http.StatusUnauthorized, "unauthorized", "missing source credentials")
		return nil, false
	}
	if p.Source.Kind != domain.SourceKindAgent {
		writeHTTPError(w, http.StatusForbidden, "agent_required", "MCP endpoint requires an agent source")
		return nil, false
	}
	return p.Source, true
}

func (s *Server) handleDelete(w http.ResponseWriter, r *http.Request) {
	src, ok := s.requireAgent(w, r)
	if !ok {
		return
	}
	sid := strings.TrimSpace(r.Header.Get(SessionHeader))
	if sid == "" {
		writeHTTPError(w, http.StatusBadRequest, "missing_session", "Mcp-Session-Id header is required")
		return
	}
	s.mu.Lock()
	owner, exists := s.sessions[sid]
	if exists && owner == src.ID {
		delete(s.sessions, sid)
	}
	s.mu.Unlock()
	if !exists || owner != src.ID {
		writeHTTPError(w, http.StatusNotFound, "session_not_found", "invalid or unknown MCP session")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handlePost(w http.ResponseWriter, r *http.Request) {
	src, ok := s.requireAgent(w, r)
	if !ok {
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 2<<20))
	if err != nil {
		writeRPC(w, http.StatusBadRequest, rpcResponse{
			JSONRPC: "2.0",
			Error:   &rpcError{Code: -32700, Message: "failed to read request body"},
		})
		return
	}

	var req rpcRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeRPC(w, http.StatusBadRequest, rpcResponse{
			JSONRPC: "2.0",
			Error:   &rpcError{Code: -32700, Message: "parse error"},
		})
		return
	}
	if req.JSONRPC != "2.0" || req.Method == "" {
		writeRPC(w, http.StatusBadRequest, rpcResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Error:   &rpcError{Code: -32600, Message: "invalid JSON-RPC 2.0 request"},
		})
		return
	}

	// Handle initialize and issue Mcp-Session-Id.
	if req.Method == "initialize" {
		sid := domain.NewID()
		s.mu.Lock()
		s.sessions[sid] = src.ID
		s.mu.Unlock()

		w.Header().Set(SessionHeader, sid)
		writeRPC(w, http.StatusOK, rpcResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"protocolVersion": ProtocolVersion,
				"capabilities": map[string]any{
					"tools": map[string]any{
						"listChanged": false,
					},
				},
				"serverInfo": map[string]any{
					"name":    "dinglin",
					"version": config.Version,
				},
			},
		})
		return
	}

	// All subsequent calls require a valid Mcp-Session-Id bound to the same agent source.
	sid := strings.TrimSpace(r.Header.Get(SessionHeader))
	if sid == "" {
		writeHTTPError(w, http.StatusBadRequest, "missing_session", "Mcp-Session-Id header is required")
		return
	}
	s.mu.RLock()
	owner, exists := s.sessions[sid]
	s.mu.RUnlock()
	if !exists || owner != src.ID {
		writeHTTPError(w, http.StatusNotFound, "session_not_found", "invalid or expired MCP session")
		return
	}

	// JSON-RPC notifications (no ID or notifications/*) return 202 Accepted with empty body.
	if len(req.ID) == 0 || string(req.ID) == "null" || strings.HasPrefix(req.Method, "notifications/") {
		w.WriteHeader(http.StatusAccepted)
		return
	}

	switch req.Method {
	case "ping":
		writeRPC(w, http.StatusOK, rpcResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result:  map[string]any{},
		})
	case "tools/list":
		writeRPC(w, http.StatusOK, rpcResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"tools": toolDefinitions(),
			},
		})
	case "tools/call":
		var params struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(req.Params, &params); err != nil || params.Name == "" {
			writeRPC(w, http.StatusOK, rpcResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
				Error:   &rpcError{Code: -32602, Message: "invalid tools/call params"},
			})
			return
		}
		result, rpcErr := s.callTool(r.Context(), src, params.Name, params.Arguments)
		if rpcErr != nil {
			writeRPC(w, http.StatusOK, rpcResponse{
				JSONRPC: "2.0",
				ID:      req.ID,
				Error:   rpcErr,
			})
			return
		}
		writeRPC(w, http.StatusOK, rpcResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result:  result,
		})
	default:
		writeRPC(w, http.StatusOK, rpcResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Error:   &rpcError{Code: -32601, Message: fmt.Sprintf("method not found: %s", req.Method)},
		})
	}
}

func (s *Server) callTool(ctx context.Context, src *domain.Source, name string, rawArgs json.RawMessage) (map[string]any, *rpcError) {
	if len(rawArgs) == 0 {
		rawArgs = []byte("{}")
	}
	switch name {
	case "send_notification":
		var args struct {
			Title          string               `json:"title"`
			Body           string               `json:"body"`
			Priority       string               `json:"priority"`
			Category       string               `json:"category"`
			Actions        []domain.QuickAction `json:"actions"`
			ExpiresInSec   int                  `json:"expires_in_sec"`
			IdempotencyKey string               `json:"idempotency_key"`
			CallbackURL    string               `json:"callback_url"`
		}
		if err := json.Unmarshal(rawArgs, &args); err != nil {
			return toolError("invalid arguments: " + err.Error()), nil
		}
		srcID := src.ID
		n, dedup, err := s.notifySvc.Create(ctx, notify.CreateInput{
			SourceID:       &srcID,
			Title:          args.Title,
			Body:           args.Body,
			Priority:       args.Priority,
			Category:       args.Category,
			Actions:        args.Actions,
			ExpiresInSec:   args.ExpiresInSec,
			IdempotencyKey: args.IdempotencyKey,
			CallbackURL:    args.CallbackURL,
		})
		if err != nil {
			return toolError(err.Error()), nil
		}
		return toolSuccess(map[string]any{
			"notification": n,
			"deduplicated": dedup,
		}), nil

	case "get_notification_receipts":
		var args struct {
			NotificationID string `json:"notification_id"`
		}
		if err := json.Unmarshal(rawArgs, &args); err != nil || strings.TrimSpace(args.NotificationID) == "" {
			return toolError("notification_id is required"), nil
		}
		n, err := s.notifySvc.GetByID(ctx, args.NotificationID)
		if err != nil {
			return toolError("notification not found"), nil
		}
		if n.SourceID == nil || *n.SourceID != src.ID {
			return toolError("forbidden: notification does not belong to current agent"), nil
		}
		receipts, err := s.callbackSvc.ListReceipts(ctx, n.ID)
		if err != nil {
			return toolError(err.Error()), nil
		}
		return toolSuccess(map[string]any{
			"notification_id": n.ID,
			"status":          n.Status,
			"receipts":        receipts,
		}), nil

	case "list_notifications":
		var args struct {
			Q        string `json:"q"`
			Priority string `json:"priority"`
			Status   string `json:"status"`
			Limit    int    `json:"limit"`
		}
		if err := json.Unmarshal(rawArgs, &args); err != nil {
			return toolError("invalid arguments: " + err.Error()), nil
		}
		items, err := s.notifySvc.List(ctx, notify.ListFilter{
			Q:        args.Q,
			SourceID: src.ID,
			Priority: args.Priority,
			Status:   args.Status,
			Limit:    args.Limit,
		})
		if err != nil {
			return toolError(err.Error()), nil
		}
		return toolSuccess(map[string]any{"items": items}), nil

	case "create_schedule":
		var args struct {
			Kind          string `json:"kind"`
			Title         string `json:"title"`
			Body          string `json:"body"`
			Priority      string `json:"priority"`
			ScheduleType  string `json:"schedule_type"`
			FireAt        string `json:"fire_at"`
			CronExpr      string `json:"cron_expr"`
			Timezone      string `json:"timezone"`
			DurationSec   int    `json:"duration_sec"`
			SnoozeMinutes int    `json:"snooze_minutes"`
		}
		if err := json.Unmarshal(rawArgs, &args); err != nil {
			return toolError("invalid arguments: " + err.Error()), nil
		}
		var fireAt *time.Time
		if strings.TrimSpace(args.FireAt) != "" {
			t, err := time.Parse(time.RFC3339, strings.TrimSpace(args.FireAt))
			if err != nil {
				return toolError("invalid fire_at: must be RFC3339"), nil
			}
			u := t.UTC()
			fireAt = &u
		}
		srcID := src.ID
		sc, err := s.scheduleSvc.Create(ctx, schedule.CreateInput{
			SourceID:      &srcID,
			Kind:          args.Kind,
			Title:         args.Title,
			Body:          args.Body,
			Priority:      args.Priority,
			ScheduleType:  args.ScheduleType,
			FireAt:        fireAt,
			CronExpr:      args.CronExpr,
			Timezone:      args.Timezone,
			DurationSec:   args.DurationSec,
			SnoozeMinutes: args.SnoozeMinutes,
		})
		if err != nil {
			return toolError(err.Error()), nil
		}
		return toolSuccess(sc), nil

	case "list_schedules":
		var args struct {
			Kind        string `json:"kind"`
			EnabledOnly bool   `json:"enabled_only"`
		}
		if err := json.Unmarshal(rawArgs, &args); err != nil {
			return toolError("invalid arguments: " + err.Error()), nil
		}
		items, err := s.scheduleSvc.List(ctx, schedule.ListFilter{
			Kind:        args.Kind,
			SourceID:    src.ID,
			EnabledOnly: args.EnabledOnly,
		})
		if err != nil {
			return toolError(err.Error()), nil
		}
		return toolSuccess(map[string]any{"items": items}), nil

	case "update_schedule":
		var args struct {
			ID              string  `json:"id"`
			Title           *string `json:"title"`
			Enabled         *bool   `json:"enabled"`
			FireAt          *string `json:"fire_at"`
			CronExpr        *string `json:"cron_expr"`
			SnoozeMinutes   *int    `json:"snooze_minutes"`
			CountdownAction string  `json:"countdown_action"`
		}
		if err := json.Unmarshal(rawArgs, &args); err != nil || strings.TrimSpace(args.ID) == "" {
			return toolError("id is required"), nil
		}
		existing, err := s.scheduleSvc.GetByID(ctx, args.ID)
		if err != nil {
			if errors.Is(err, schedule.ErrNotFound) {
				return toolError("schedule not found"), nil
			}
			return toolError(err.Error()), nil
		}
		if existing.SourceID == nil || *existing.SourceID != src.ID {
			return toolError("forbidden: schedule does not belong to current agent"), nil
		}

		var fireAt *time.Time
		if args.FireAt != nil && strings.TrimSpace(*args.FireAt) != "" {
			t, err := time.Parse(time.RFC3339, strings.TrimSpace(*args.FireAt))
			if err != nil {
				return toolError("invalid fire_at: must be RFC3339"), nil
			}
			u := t.UTC()
			fireAt = &u
		}

		updated := existing
		if args.Title != nil || args.Enabled != nil || fireAt != nil || args.CronExpr != nil || args.SnoozeMinutes != nil {
			updated, err = s.scheduleSvc.Update(ctx, existing.ID, schedule.UpdateInput{
				Title:         args.Title,
				Enabled:       args.Enabled,
				FireAt:        fireAt,
				CronExpr:      args.CronExpr,
				SnoozeMinutes: args.SnoozeMinutes,
			})
			if err != nil {
				return toolError(err.Error()), nil
			}
		}
		if strings.TrimSpace(args.CountdownAction) != "" {
			updated, err = s.scheduleSvc.CountdownAction(ctx, existing.ID, strings.TrimSpace(args.CountdownAction))
			if err != nil {
				return toolError(err.Error()), nil
			}
		}
		return toolSuccess(updated), nil

	case "delete_schedule":
		var args struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(rawArgs, &args); err != nil || strings.TrimSpace(args.ID) == "" {
			return toolError("id is required"), nil
		}
		existing, err := s.scheduleSvc.GetByID(ctx, args.ID)
		if err != nil {
			if errors.Is(err, schedule.ErrNotFound) {
				return toolError("schedule not found"), nil
			}
			return toolError(err.Error()), nil
		}
		if existing.SourceID == nil || *existing.SourceID != src.ID {
			return toolError("forbidden: schedule does not belong to current agent"), nil
		}
		if err := s.scheduleSvc.Delete(ctx, existing.ID); err != nil {
			return toolError(err.Error()), nil
		}
		return toolSuccess(map[string]any{"deleted": true, "id": existing.ID}), nil

	default:
		return nil, &rpcError{Code: -32601, Message: fmt.Sprintf("unknown tool: %s", name)}
	}
}

func toolSuccess(data any) map[string]any {
	b, _ := json.Marshal(data)
	return map[string]any{
		"content": []map[string]any{
			{"type": "text", "text": string(b)},
		},
		"isError": false,
	}
}

func toolError(msg string) map[string]any {
	return map[string]any{
		"content": []map[string]any{
			{"type": "text", "text": msg},
		},
		"isError": true,
	}
}

func writeRPC(w http.ResponseWriter, status int, resp rpcResponse) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(resp)
}

func writeHTTPError(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]string{
			"code":    code,
			"message": msg,
		},
	})
}

func toolDefinitions() []map[string]any {
	return []map[string]any{
		{
			"name":        "send_notification",
			"description": "Send a notification to the owner via Dinglin.",
			"inputSchema": map[string]any{
				"type":     "object",
				"required": []string{"title"},
				"properties": map[string]any{
					"title":           map[string]any{"type": "string"},
					"body":            map[string]any{"type": "string"},
					"priority":        map[string]any{"type": "string", "enum": []string{"silent", "normal", "critical"}},
					"category":        map[string]any{"type": "string"},
					"expires_in_sec":  map[string]any{"type": "integer", "minimum": 1},
					"idempotency_key": map[string]any{"type": "string"},
					"callback_url":    map[string]any{"type": "string"},
					"actions": map[string]any{
						"type": "array",
						"items": map[string]any{
							"type":     "object",
							"required": []string{"id", "label"},
							"properties": map[string]any{
								"id":      map[string]any{"type": "string"},
								"label":   map[string]any{"type": "string"},
								"style":   map[string]any{"type": "string"},
								"payload": map[string]any{"type": "object"},
							},
						},
					},
				},
			},
		},
		{
			"name":        "get_notification_receipts",
			"description": "Get user action receipts for a notification sent by this agent.",
			"inputSchema": map[string]any{
				"type":     "object",
				"required": []string{"notification_id"},
				"properties": map[string]any{
					"notification_id": map[string]any{"type": "string"},
				},
			},
		},
		{
			"name":        "list_notifications",
			"description": "List notifications previously sent by this agent.",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"q":        map[string]any{"type": "string"},
					"priority": map[string]any{"type": "string", "enum": []string{"silent", "normal", "critical"}},
					"status":   map[string]any{"type": "string", "enum": []string{"unread", "read", "acked", "snoozed", "dismissed"}},
					"limit":    map[string]any{"type": "integer", "minimum": 1, "maximum": 200},
				},
			},
		},
		{
			"name":        "create_schedule",
			"description": "Create a scheduled notification, alarm, or countdown owned by this agent.",
			"inputSchema": map[string]any{
				"type":     "object",
				"required": []string{"kind", "title", "schedule_type"},
				"properties": map[string]any{
					"kind":           map[string]any{"type": "string", "enum": []string{"scheduled_notification", "alarm", "countdown"}},
					"title":          map[string]any{"type": "string"},
					"body":           map[string]any{"type": "string"},
					"priority":       map[string]any{"type": "string", "enum": []string{"silent", "normal", "critical"}},
					"schedule_type":  map[string]any{"type": "string", "enum": []string{"once", "cron", "duration"}},
					"fire_at":        map[string]any{"type": "string", "format": "date-time"},
					"cron_expr":      map[string]any{"type": "string"},
					"timezone":       map[string]any{"type": "string"},
					"duration_sec":   map[string]any{"type": "integer", "minimum": 1},
					"snooze_minutes": map[string]any{"type": "integer", "minimum": 1},
				},
			},
		},
		{
			"name":        "list_schedules",
			"description": "List schedules owned by this agent.",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"kind":         map[string]any{"type": "string", "enum": []string{"scheduled_notification", "alarm", "countdown"}},
					"enabled_only": map[string]any{"type": "boolean"},
				},
			},
		},
		{
			"name":        "update_schedule",
			"description": "Update a schedule or trigger a countdown action on a schedule owned by this agent.",
			"inputSchema": map[string]any{
				"type":     "object",
				"required": []string{"id"},
				"properties": map[string]any{
					"id":               map[string]any{"type": "string"},
					"title":            map[string]any{"type": "string"},
					"enabled":          map[string]any{"type": "boolean"},
					"fire_at":          map[string]any{"type": "string", "format": "date-time"},
					"cron_expr":        map[string]any{"type": "string"},
					"snooze_minutes":   map[string]any{"type": "integer", "minimum": 1},
					"countdown_action": map[string]any{"type": "string", "enum": []string{"start", "pause", "resume", "reset", "cancel"}},
				},
			},
		},
		{
			"name":        "delete_schedule",
			"description": "Delete a schedule owned by this agent.",
			"inputSchema": map[string]any{
				"type":     "object",
				"required": []string{"id"},
				"properties": map[string]any{
					"id": map[string]any{"type": "string"},
				},
			},
		},
	}
}
