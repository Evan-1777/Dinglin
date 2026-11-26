package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"dinglin/server/internal/auth"
	"dinglin/server/internal/domain"
	"dinglin/server/internal/push"
)

func (s *Server) RegisterSyncAndPushRoutes(hub *push.WSHub, dispatcher *push.Dispatcher) {
	s.SetOnlineChecker(hub)
	s.RegisterRoutes(func(mux *http.ServeMux) {
		mux.Handle("GET /api/v1/sync", s.auth.RequireOwner(http.HandlerFunc(s.handleSync)))
		mux.HandleFunc("GET /api/v1/ws", func(w http.ResponseWriter, r *http.Request) {
			s.handleWS(w, r, hub)
		})
		mux.Handle("POST /api/v1/devices/{id}/test", s.auth.RequireOwner(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleTestDevicePush(w, r, dispatcher)
		})))
	})
}

func (s *Server) handleSync(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	sinceSeq, _ := strconv.ParseInt(q.Get("since_seq"), 10, 64)
	limit, _ := strconv.Atoi(q.Get("limit"))
	if limit <= 0 || limit > 200 {
		limit = 100
	}

	rows, err := s.store.DB.QueryContext(r.Context(), `
		SELECT e.seq, e.event_type, e.entity_id, e.payload_json, e.created_at, n.expires_at
		FROM sync_events e
		LEFT JOIN notifications n ON e.event_type = 'notification.created' AND n.id = e.entity_id
		WHERE e.seq > ?
		ORDER BY e.seq ASC
		LIMIT ?`, sinceSeq, limit+1)
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	defer rows.Close()

	nowUnix := time.Now().UTC().Unix()
	events := make([]domain.SyncEvent, 0)
	latestSeq := sinceSeq
	hasMore := false
	seen := 0

	for rows.Next() {
		var (
			ev        domain.SyncEvent
			payload   string
			createdAt int64
			expiresAt sql.NullInt64
		)
		if err := rows.Scan(&ev.Seq, &ev.EventType, &ev.EntityID, &payload, &createdAt, &expiresAt); err != nil {
			WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
			return
		}
		seen++
		if seen > limit {
			hasMore = true
			break
		}
		latestSeq = ev.Seq
		// Skip expired notification.created events during offline catch-up.
		if ev.EventType == "notification.created" && expiresAt.Valid && expiresAt.Int64 <= nowUnix {
			continue
		}
		ev.Payload = json.RawMessage(payload)
		ev.CreatedAt = time.Unix(createdAt, 0).UTC()
		events = append(events, ev)
	}

	WriteJSON(w, http.StatusOK, map[string]any{
		"events":     events,
		"latest_seq": latestSeq,
		"has_more":   hasMore,
	})
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request, hub *push.WSHub) {
	tok := auth.ExtractToken(r, true)
	p, err := s.auth.AuthenticateOwner(r.Context(), tok)
	if err != nil {
		WriteError(w, http.StatusUnauthorized, "unauthorized", "invalid or missing token")
		return
	}
	deviceID := push.MasterSessionKey
	if p.Device != nil {
		deviceID = p.Device.ID
	}
	hub.ServeWS(w, r, deviceID)
}

func (s *Server) handleTestDevicePush(w http.ResponseWriter, r *http.Request, dispatcher *push.Dispatcher) {
	id := r.PathValue("id")
	payload, _ := json.Marshal(map[string]any{
		"title":   "Dinglin 测试推送",
		"body":    "通道连通性验证成功",
		"sent_at": time.Now().UTC(),
	})
	channel, err := dispatcher.SendToDevice(r.Context(), id, push.EventMessage{
		Seq:       0,
		EventType: "device.test",
		EntityID:  id,
		Priority:  domain.PriorityNormal,
		Title:     "Dinglin 测试推送",
		Data:      payload,
	})
	if errors.Is(err, sql.ErrNoRows) {
		WriteError(w, http.StatusNotFound, "not_found", "device not found")
		return
	}
	if err != nil {
		WriteError(w, http.StatusBadGateway, "push_failed", err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{
		"device_id": id,
		"channel":   channel,
	})
}
