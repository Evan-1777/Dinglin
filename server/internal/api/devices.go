package api

import (
	"database/sql"
	"errors"
	"net/http"
	"strings"
	"time"

	"dinglin/server/internal/auth"
	"dinglin/server/internal/domain"
	"dinglin/server/internal/store"
)

func (s *Server) handleCreatePairingCode(w http.ResponseWriter, r *http.Request) {
	code, expiresAt, err := s.pairing.Issue(time.Now().UTC())
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "pairing_error", err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]any{
		"code":       code,
		"expires_at": expiresAt,
		"ttl_sec":    int(PairingCodeTTL.Seconds()),
	})
}

func (s *Server) handlePairDevice(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code     string `json:"code"`
		Name     string `json:"name"`
		Platform string `json:"platform"`
		HasGMS   bool   `json:"has_gms"`
	}
	if err := DecodeJSON(r, &req); err != nil {
		WriteError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	req.Code = strings.TrimSpace(req.Code)
	req.Name = strings.TrimSpace(req.Name)
	req.Platform = strings.ToLower(strings.TrimSpace(req.Platform))
	if req.Name == "" || !domain.ValidPlatform(req.Platform) {
		WriteError(w, http.StatusBadRequest, "validation_error", "name is required and platform must be android or web")
		return
	}
	if !s.pairing.Consume(req.Code, time.Now().UTC()) {
		WriteError(w, http.StatusUnauthorized, "invalid_pairing_code", "pairing code is invalid, used, or expired")
		return
	}

	plaintext, _, hash, err := auth.GenerateToken("dev_")
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "token_error", err.Error())
		return
	}
	pushMode := domain.PushModeWS
	if req.Platform == domain.PlatformWeb {
		pushMode = domain.PushModeWeb
	}
	now := time.Now().UTC()
	dev := domain.Device{
		ID:         domain.NewID(),
		Name:       req.Name,
		Platform:   req.Platform,
		TokenHash:  hash,
		HasGMS:     req.HasGMS,
		PushMode:   pushMode,
		LastSeenAt: &now,
		CreatedAt:  now,
	}

	_, err = s.store.DB.ExecContext(r.Context(), `
		INSERT INTO devices (id, name, platform, token_hash, fcm_token, has_gms, push_mode, last_seen_at, created_at)
		VALUES (?, ?, ?, ?, '', ?, ?, ?, ?)`,
		dev.ID, dev.Name, dev.Platform, dev.TokenHash, store.BoolToInt(dev.HasGMS), dev.PushMode, now.Unix(), now.Unix(),
	)
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}

	WriteJSON(w, http.StatusCreated, map[string]any{
		"device":       dev,
		"device_id":    dev.ID,
		"device_token": plaintext,
	})
}

func (s *Server) handleListDevices(w http.ResponseWriter, r *http.Request) {
	rows, err := s.store.DB.QueryContext(r.Context(), `
		SELECT id, name, platform, fcm_token, has_gms, push_mode, last_seen_at, created_at
		FROM devices ORDER BY created_at ASC`)
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	defer rows.Close()

	list := make([]domain.Device, 0)
	for rows.Next() {
		var (
			d          domain.Device
			hasGMS     int
			lastSeenAt sql.NullInt64
			createdAt  int64
		)
		if err := rows.Scan(&d.ID, &d.Name, &d.Platform, &d.FCMToken, &hasGMS, &d.PushMode, &lastSeenAt, &createdAt); err != nil {
			WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
			return
		}
		d.HasGMS = hasGMS != 0
		d.LastSeenAt = store.FromNullUnix(lastSeenAt)
		d.CreatedAt = time.Unix(createdAt, 0).UTC()
		if s.onlineChecker != nil {
			d.Online = s.onlineChecker.IsOnline(d.ID)
		}
		list = append(list, d)
	}
	WriteJSON(w, http.StatusOK, map[string]any{"devices": list})
}

func (s *Server) handleUpdateDevice(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req struct {
		Name *string `json:"name"`
	}
	if err := DecodeJSON(r, &req); err != nil {
		WriteError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	if req.Name == nil || strings.TrimSpace(*req.Name) == "" {
		WriteError(w, http.StatusBadRequest, "validation_error", "name is required")
		return
	}
	res, err := s.store.DB.ExecContext(r.Context(), `UPDATE devices SET name = ? WHERE id = ?`, strings.TrimSpace(*req.Name), id)
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		WriteError(w, http.StatusNotFound, "not_found", "device not found")
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"id": id, "name": strings.TrimSpace(*req.Name)})
}

func (s *Server) handleDeleteDevice(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	res, err := s.store.DB.ExecContext(r.Context(), `DELETE FROM devices WHERE id = ?`, id)
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		WriteError(w, http.StatusNotFound, "not_found", "device not found")
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"deleted": true, "id": id})
}

func (s *Server) handleUpdateFCMToken(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req struct {
		FCMToken string `json:"fcm_token"`
		HasGMS   *bool  `json:"has_gms"`
	}
	if err := DecodeJSON(r, &req); err != nil {
		WriteError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}

	var platform string
	var hasGMSInt int
	err := s.store.DB.QueryRowContext(r.Context(), `SELECT platform, has_gms FROM devices WHERE id = ?`, id).Scan(&platform, &hasGMSInt)
	if errors.Is(err, sql.ErrNoRows) {
		WriteError(w, http.StatusNotFound, "not_found", "device not found")
		return
	}
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}

	hasGMS := hasGMSInt != 0
	if req.HasGMS != nil {
		hasGMS = *req.HasGMS
	}
	fcmToken := strings.TrimSpace(req.FCMToken)
	pushMode := domain.PushModeWS
	if platform == domain.PlatformWeb {
		pushMode = domain.PushModeWeb
	} else if fcmToken != "" && hasGMS {
		pushMode = domain.PushModeFCM
	}

	_, err = s.store.DB.ExecContext(r.Context(), `
		UPDATE devices SET fcm_token = ?, has_gms = ?, push_mode = ?, last_seen_at = ? WHERE id = ?`,
		fcmToken, store.BoolToInt(hasGMS), pushMode, time.Now().UTC().Unix(), id,
	)
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{
		"id":        id,
		"has_gms":   hasGMS,
		"push_mode": pushMode,
	})
}

func (s *Server) handleGetSettings(w http.ResponseWriter, r *http.Request) {
	cfg, err := s.store.GetSettings(r.Context(), s.cfg.RetentionDays)
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"settings": cfg})
}

func (s *Server) handleUpdateSettings(w http.ResponseWriter, r *http.Request) {
	cur, err := s.store.GetSettings(r.Context(), s.cfg.RetentionDays)
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	var req struct {
		DNDEnabled           *bool   `json:"dnd_enabled"`
		DNDStart             *string `json:"dnd_start"`
		DNDEnd               *string `json:"dnd_end"`
		DefaultSnoozeMinutes *int    `json:"default_snooze_minutes"`
		RetentionDays        *int    `json:"retention_days"`
	}
	if err := DecodeJSON(r, &req); err != nil {
		WriteError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	if req.DNDEnabled != nil {
		cur.DNDEnabled = *req.DNDEnabled
	}
	if req.DNDStart != nil {
		cur.DNDStart = strings.TrimSpace(*req.DNDStart)
	}
	if req.DNDEnd != nil {
		cur.DNDEnd = strings.TrimSpace(*req.DNDEnd)
	}
	if req.DefaultSnoozeMinutes != nil {
		if *req.DefaultSnoozeMinutes <= 0 || *req.DefaultSnoozeMinutes > 1440 {
			WriteError(w, http.StatusBadRequest, "validation_error", "default_snooze_minutes must be between 1 and 1440")
			return
		}
		cur.DefaultSnoozeMinutes = *req.DefaultSnoozeMinutes
	}
	if req.RetentionDays != nil {
		if *req.RetentionDays <= 0 || *req.RetentionDays > 3650 {
			WriteError(w, http.StatusBadRequest, "validation_error", "retention_days must be between 1 and 3650")
			return
		}
		cur.RetentionDays = *req.RetentionDays
	}
	if err := s.store.SaveSettings(r.Context(), cur); err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"settings": cur})
}
