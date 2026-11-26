package api

import (
	"database/sql"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"

	"dinglin/server/internal/auth"
	"dinglin/server/internal/domain"
	"dinglin/server/internal/store"
)

var hhmmPattern = regexp.MustCompile(`^([01]\d|2[0-3]):[0-5]\d$`)

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
		Name     *string `json:"name"`
		PushMode *string `json:"push_mode"`
	}
	if err := DecodeJSON(r, &req); err != nil {
		WriteError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	if req.Name == nil && req.PushMode == nil {
		WriteError(w, http.StatusBadRequest, "validation_error", "name or push_mode is required")
		return
	}

	var (
		dev        domain.Device
		hasGMS     int
		lastSeenAt sql.NullInt64
		createdAt  int64
	)
	err := s.store.DB.QueryRowContext(r.Context(), `
		SELECT id, name, platform, fcm_token, has_gms, push_mode, last_seen_at, created_at
		FROM devices WHERE id = ?`, id,
	).Scan(&dev.ID, &dev.Name, &dev.Platform, &dev.FCMToken, &hasGMS, &dev.PushMode, &lastSeenAt, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		WriteError(w, http.StatusNotFound, "not_found", "device not found")
		return
	}
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	dev.HasGMS = hasGMS != 0
	dev.LastSeenAt = store.FromNullUnix(lastSeenAt)
	dev.CreatedAt = time.Unix(createdAt, 0).UTC()

	if req.Name != nil {
		trimmed := strings.TrimSpace(*req.Name)
		if trimmed == "" {
			WriteError(w, http.StatusBadRequest, "validation_error", "name cannot be empty")
			return
		}
		dev.Name = trimmed
	}
	if req.PushMode != nil {
		mode := strings.ToLower(strings.TrimSpace(*req.PushMode))
		if !domain.ValidPushMode(mode) {
			WriteError(w, http.StatusBadRequest, "validation_error", "invalid push_mode")
			return
		}
		if dev.Platform == domain.PlatformWeb && mode != domain.PushModeWeb {
			WriteError(w, http.StatusBadRequest, "validation_error", "web device only supports web push_mode")
			return
		}
		if dev.Platform == domain.PlatformAndroid && mode == domain.PushModeWeb {
			WriteError(w, http.StatusBadRequest, "validation_error", "android device only supports ws or fcm push_mode")
			return
		}
		if mode == domain.PushModeFCM && dev.FCMToken == "" {
			WriteError(w, http.StatusBadRequest, "validation_error", "device has no fcm_token registered")
			return
		}
		dev.PushMode = mode
	}

	if _, err := s.store.DB.ExecContext(r.Context(),
		`UPDATE devices SET name = ?, push_mode = ? WHERE id = ?`,
		dev.Name, dev.PushMode, dev.ID,
	); err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	if s.onlineChecker != nil {
		dev.Online = s.onlineChecker.IsOnline(dev.ID)
	}
	WriteJSON(w, http.StatusOK, map[string]any{"device": dev})
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
		FCMToken string  `json:"fcm_token"`
		HasGMS   *bool   `json:"has_gms"`
		PushMode *string `json:"push_mode"`
	}
	if err := DecodeJSON(r, &req); err != nil {
		WriteError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}

	var (
		platform     string
		hasGMSInt    int
		oldFCMToken  string
		oldPushMode  string
	)
	err := s.store.DB.QueryRowContext(r.Context(),
		`SELECT platform, has_gms, fcm_token, push_mode FROM devices WHERE id = ?`, id,
	).Scan(&platform, &hasGMSInt, &oldFCMToken, &oldPushMode)
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
	pushMode := oldPushMode
	if pushMode == "" {
		pushMode = domain.PushModeWS
	}
	if platform == domain.PlatformWeb {
		pushMode = domain.PushModeWeb
	} else if req.PushMode != nil {
		mode := strings.ToLower(strings.TrimSpace(*req.PushMode))
		if mode != domain.PushModeWS && mode != domain.PushModeFCM {
			WriteError(w, http.StatusBadRequest, "validation_error", "invalid push_mode")
			return
		}
		if mode == domain.PushModeFCM && fcmToken == "" {
			WriteError(w, http.StatusBadRequest, "validation_error", "fcm_token is required for fcm push_mode")
			return
		}
		pushMode = mode
	} else if fcmToken == "" && pushMode == domain.PushModeFCM {
		pushMode = domain.PushModeWS
	} else if oldFCMToken == "" && fcmToken != "" && hasGMS {
		// Auto-enable FCM only on initial token registration; token refreshes preserve manual WS override.
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
		v := strings.TrimSpace(*req.DNDStart)
		if !hhmmPattern.MatchString(v) {
			WriteError(w, http.StatusBadRequest, "validation_error", "dnd_start must be HH:MM (00:00-23:59)")
			return
		}
		cur.DNDStart = v
	}
	if req.DNDEnd != nil {
		v := strings.TrimSpace(*req.DNDEnd)
		if !hhmmPattern.MatchString(v) {
			WriteError(w, http.StatusBadRequest, "validation_error", "dnd_end must be HH:MM (00:00-23:59)")
			return
		}
		cur.DNDEnd = v
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
