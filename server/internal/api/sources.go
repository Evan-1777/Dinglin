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

var slugPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,62}$`)

func (s *Server) handleListSources(w http.ResponseWriter, r *http.Request) {
	rows, err := s.store.DB.QueryContext(r.Context(), `
		SELECT id, slug, name, kind, color, token_prefix, callback_url, enabled, created_at, updated_at
		FROM sources ORDER BY created_at ASC`)
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	defer rows.Close()

	list := make([]domain.Source, 0)
	for rows.Next() {
		var (
			src       domain.Source
			enabled   int
			createdAt int64
			updatedAt int64
		)
		if err := rows.Scan(&src.ID, &src.Slug, &src.Name, &src.Kind, &src.Color, &src.TokenPrefix, &src.CallbackURL, &enabled, &createdAt, &updatedAt); err != nil {
			WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
			return
		}
		src.Enabled = enabled != 0
		src.CreatedAt = time.Unix(createdAt, 0).UTC()
		src.UpdatedAt = time.Unix(updatedAt, 0).UTC()
		list = append(list, src)
	}
	WriteJSON(w, http.StatusOK, map[string]any{"sources": list})
}

func (s *Server) handleCreateSource(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Slug        string `json:"slug"`
		Name        string `json:"name"`
		Kind        string `json:"kind"`
		Color       string `json:"color"`
		CallbackURL string `json:"callback_url"`
	}
	if err := DecodeJSON(r, &req); err != nil {
		WriteError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	req.Slug = strings.ToLower(strings.TrimSpace(req.Slug))
	req.Name = strings.TrimSpace(req.Name)
	req.Kind = strings.TrimSpace(req.Kind)
	if req.Kind == "" {
		req.Kind = domain.SourceKindWebhook
	}
	req.Color = strings.TrimSpace(req.Color)
	if req.Color == "" {
		req.Color = "#007AFF"
	}
	req.CallbackURL = strings.TrimSpace(req.CallbackURL)

	if req.Name == "" || !slugPattern.MatchString(req.Slug) {
		WriteError(w, http.StatusBadRequest, "validation_error", "name is required and slug must match [a-z0-9][a-z0-9_-]{0,62}")
		return
	}
	if !domain.ValidSourceKind(req.Kind) {
		WriteError(w, http.StatusBadRequest, "validation_error", "kind must be webhook or agent")
		return
	}

	plaintext, prefix, hash, err := auth.GenerateToken("src_")
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "token_error", err.Error())
		return
	}
	cbSecret, _, _, err := auth.GenerateToken("whsec_")
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "token_error", err.Error())
		return
	}

	now := time.Now().UTC()
	src := domain.Source{
		ID:             domain.NewID(),
		Slug:           req.Slug,
		Name:           req.Name,
		Kind:           req.Kind,
		Color:          req.Color,
		TokenHash:      hash,
		TokenPrefix:    prefix,
		CallbackURL:    req.CallbackURL,
		CallbackSecret: cbSecret,
		Enabled:        true,
		CreatedAt:      now,
		UpdatedAt:      now,
	}

	_, err = s.store.DB.ExecContext(r.Context(), `
		INSERT INTO sources (id, slug, name, kind, color, token_hash, token_prefix, callback_url, callback_secret, enabled, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)`,
		src.ID, src.Slug, src.Name, src.Kind, src.Color, src.TokenHash, src.TokenPrefix, src.CallbackURL, src.CallbackSecret, now.Unix(), now.Unix(),
	)
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE") {
			WriteError(w, http.StatusConflict, "slug_exists", "source slug already exists")
			return
		}
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}

	WriteJSON(w, http.StatusCreated, map[string]any{
		"source":          src,
		"token":           plaintext,
		"callback_secret": cbSecret,
	})
}

func (s *Server) handleUpdateSource(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req struct {
		Name        *string `json:"name"`
		Color       *string `json:"color"`
		CallbackURL *string `json:"callback_url"`
		Enabled     *bool   `json:"enabled"`
	}
	if err := DecodeJSON(r, &req); err != nil {
		WriteError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}

	var (
		src       domain.Source
		enabled   int
		createdAt int64
		updatedAt int64
	)
	err := s.store.DB.QueryRowContext(r.Context(), `
		SELECT id, slug, name, kind, color, token_prefix, callback_url, enabled, created_at, updated_at
		FROM sources WHERE id = ?`, id).Scan(
		&src.ID, &src.Slug, &src.Name, &src.Kind, &src.Color, &src.TokenPrefix, &src.CallbackURL, &enabled, &createdAt, &updatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		WriteError(w, http.StatusNotFound, "not_found", "source not found")
		return
	}
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	src.Enabled = enabled != 0
	src.CreatedAt = time.Unix(createdAt, 0).UTC()

	if req.Name != nil {
		trimmed := strings.TrimSpace(*req.Name)
		if trimmed == "" {
			WriteError(w, http.StatusBadRequest, "validation_error", "name cannot be empty")
			return
		}
		src.Name = trimmed
	}
	if req.Color != nil {
		src.Color = strings.TrimSpace(*req.Color)
	}
	if req.CallbackURL != nil {
		src.CallbackURL = strings.TrimSpace(*req.CallbackURL)
	}
	if req.Enabled != nil {
		src.Enabled = *req.Enabled
	}
	src.UpdatedAt = time.Now().UTC()

	_, err = s.store.DB.ExecContext(r.Context(), `
		UPDATE sources SET name = ?, color = ?, callback_url = ?, enabled = ?, updated_at = ?
		WHERE id = ?`,
		src.Name, src.Color, src.CallbackURL, store.BoolToInt(src.Enabled), src.UpdatedAt.Unix(), src.ID,
	)
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"source": src})
}

func (s *Server) handleRotateSourceToken(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	plaintext, prefix, hash, err := auth.GenerateToken("src_")
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "token_error", err.Error())
		return
	}
	now := time.Now().UTC()
	res, err := s.store.DB.ExecContext(r.Context(), `
		UPDATE sources SET token_hash = ?, token_prefix = ?, updated_at = ? WHERE id = ?`,
		hash, prefix, now.Unix(), id,
	)
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		WriteError(w, http.StatusNotFound, "not_found", "source not found")
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{
		"id":           id,
		"token":        plaintext,
		"token_prefix": prefix,
	})
}

func (s *Server) handleDeleteSource(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	res, err := s.store.DB.ExecContext(r.Context(), `DELETE FROM sources WHERE id = ?`, id)
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		WriteError(w, http.StatusNotFound, "not_found", "source not found")
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"deleted": true, "id": id})
}
