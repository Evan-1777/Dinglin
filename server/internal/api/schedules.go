package api

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"dinglin/server/internal/schedule"
)

func (s *Server) RegisterScheduleRoutes(schedSvc *schedule.Service) {
	s.RegisterRoutes(func(mux *http.ServeMux) {
		mux.Handle("GET /api/v1/schedules", s.auth.RequireOwner(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleListSchedules(w, r, schedSvc)
		})))
		mux.Handle("POST /api/v1/schedules", s.auth.RequireOwner(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleCreateSchedule(w, r, schedSvc)
		})))
		mux.Handle("PATCH /api/v1/schedules/{id}", s.auth.RequireOwner(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleUpdateSchedule(w, r, schedSvc)
		})))
		mux.Handle("DELETE /api/v1/schedules/{id}", s.auth.RequireOwner(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleDeleteSchedule(w, r, schedSvc)
		})))
		mux.Handle("POST /api/v1/schedules/{id}/toggle", s.auth.RequireOwner(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleToggleSchedule(w, r, schedSvc)
		})))
		mux.Handle("POST /api/v1/schedules/{id}/snooze", s.auth.RequireOwner(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleSnoozeSchedule(w, r, schedSvc)
		})))
		mux.Handle("POST /api/v1/schedules/{id}/dismiss", s.auth.RequireOwner(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleDismissSchedule(w, r, schedSvc)
		})))
		mux.Handle("POST /api/v1/schedules/{id}/action", s.auth.RequireOwner(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleCountdownAction(w, r, schedSvc)
		})))
		mux.Handle("POST /api/v1/schedules/{id}/triggered", s.auth.RequireOwner(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleScheduleTriggered(w, r, schedSvc)
		})))
	})
}

func (s *Server) handleListSchedules(w http.ResponseWriter, r *http.Request, schedSvc *schedule.Service) {
	q := r.URL.Query()
	list, err := schedSvc.List(r.Context(), schedule.ListFilter{
		Kind:        strings.TrimSpace(q.Get("kind")),
		SourceID:    strings.TrimSpace(q.Get("source_id")),
		EnabledOnly: q.Get("enabled_only") == "true" || q.Get("enabled_only") == "1",
	})
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"schedules": list})
}

func (s *Server) handleCreateSchedule(w http.ResponseWriter, r *http.Request, schedSvc *schedule.Service) {
	var req struct {
		Kind          string     `json:"kind"`
		Title         string     `json:"title"`
		Body          string     `json:"body"`
		Priority      string     `json:"priority"`
		ScheduleType  string     `json:"schedule_type"`
		FireAt        *time.Time `json:"fire_at"`
		CronExpr      string     `json:"cron_expr"`
		Timezone      string     `json:"timezone"`
		DurationSec   int        `json:"duration_sec"`
		SnoozeMinutes int        `json:"snooze_minutes"`
		SoundProfile  string     `json:"sound_profile"`
		Vibrate       *bool      `json:"vibrate"`
		Enabled       *bool      `json:"enabled"`
		AutoStart     bool       `json:"auto_start"`
	}
	if err := DecodeJSON(r, &req); err != nil {
		WriteError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	sc, err := schedSvc.Create(r.Context(), schedule.CreateInput{
		Kind:          req.Kind,
		Title:         req.Title,
		Body:          req.Body,
		Priority:      req.Priority,
		ScheduleType:  req.ScheduleType,
		FireAt:        req.FireAt,
		CronExpr:      req.CronExpr,
		Timezone:      req.Timezone,
		DurationSec:   req.DurationSec,
		SnoozeMinutes: req.SnoozeMinutes,
		SoundProfile:  req.SoundProfile,
		Vibrate:       req.Vibrate,
		Enabled:       req.Enabled,
		AutoStart:     req.AutoStart,
	})
	if err != nil {
		if errors.Is(err, schedule.ErrValidation) {
			WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
			return
		}
		WriteError(w, http.StatusInternalServerError, "schedule_error", err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]any{"schedule": sc})
}

func (s *Server) handleUpdateSchedule(w http.ResponseWriter, r *http.Request, schedSvc *schedule.Service) {
	id := r.PathValue("id")
	var req struct {
		Title         *string    `json:"title"`
		Body          *string    `json:"body"`
		Priority      *string    `json:"priority"`
		ScheduleType  *string    `json:"schedule_type"`
		FireAt        *time.Time `json:"fire_at"`
		CronExpr      *string    `json:"cron_expr"`
		Timezone      *string    `json:"timezone"`
		DurationSec   *int       `json:"duration_sec"`
		SnoozeMinutes *int       `json:"snooze_minutes"`
		SoundProfile  *string    `json:"sound_profile"`
		Vibrate       *bool      `json:"vibrate"`
		Enabled       *bool      `json:"enabled"`
	}
	if err := DecodeJSON(r, &req); err != nil {
		WriteError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	sc, err := schedSvc.Update(r.Context(), id, schedule.UpdateInput{
		Title:         req.Title,
		Body:          req.Body,
		Priority:      req.Priority,
		ScheduleType:  req.ScheduleType,
		FireAt:        req.FireAt,
		CronExpr:      req.CronExpr,
		Timezone:      req.Timezone,
		DurationSec:   req.DurationSec,
		SnoozeMinutes: req.SnoozeMinutes,
		SoundProfile:  req.SoundProfile,
		Vibrate:       req.Vibrate,
		Enabled:       req.Enabled,
	})
	if err != nil {
		writeScheduleErr(w, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"schedule": sc})
}

func (s *Server) handleDeleteSchedule(w http.ResponseWriter, r *http.Request, schedSvc *schedule.Service) {
	id := r.PathValue("id")
	if err := schedSvc.Delete(r.Context(), id); err != nil {
		writeScheduleErr(w, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"deleted": true, "id": id})
}

func (s *Server) handleToggleSchedule(w http.ResponseWriter, r *http.Request, schedSvc *schedule.Service) {
	id := r.PathValue("id")
	var req struct {
		Enabled *bool `json:"enabled"`
	}
	_ = DecodeJSON(r, &req)
	sc, err := schedSvc.Toggle(r.Context(), id, req.Enabled)
	if err != nil {
		writeScheduleErr(w, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"schedule": sc})
}

func (s *Server) handleSnoozeSchedule(w http.ResponseWriter, r *http.Request, schedSvc *schedule.Service) {
	id := r.PathValue("id")
	var req struct {
		Minutes int `json:"minutes"`
	}
	_ = DecodeJSON(r, &req)
	sc, err := schedSvc.Snooze(r.Context(), id, req.Minutes)
	if err != nil {
		writeScheduleErr(w, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"schedule": sc})
}

func (s *Server) handleDismissSchedule(w http.ResponseWriter, r *http.Request, schedSvc *schedule.Service) {
	id := r.PathValue("id")
	sc, err := schedSvc.Dismiss(r.Context(), id)
	if err != nil {
		writeScheduleErr(w, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"schedule": sc})
}

func (s *Server) handleCountdownAction(w http.ResponseWriter, r *http.Request, schedSvc *schedule.Service) {
	id := r.PathValue("id")
	var req struct {
		Action string `json:"action"`
	}
	if err := DecodeJSON(r, &req); err != nil {
		WriteError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	sc, err := schedSvc.CountdownAction(r.Context(), id, strings.ToLower(strings.TrimSpace(req.Action)))
	if err != nil {
		writeScheduleErr(w, err)
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"schedule": sc})
}

func (s *Server) handleScheduleTriggered(w http.ResponseWriter, r *http.Request, schedSvc *schedule.Service) {
	id := r.PathValue("id")
	var req struct {
		OccurrenceKey string     `json:"occurrence_key"`
		FiredAt       *time.Time `json:"fired_at"`
	}
	_ = DecodeJSON(r, &req)
	firedAt := time.Now().UTC()
	if req.FiredAt != nil {
		firedAt = req.FiredAt.UTC()
	}
	notif, dedup, sc, err := schedSvc.MarkTriggered(r.Context(), id, strings.TrimSpace(req.OccurrenceKey), firedAt)
	if err != nil {
		writeScheduleErr(w, err)
		return
	}
	var notifVal any
	if notif.ID != "" {
		notifVal = notif
	}
	WriteJSON(w, http.StatusOK, map[string]any{
		"notification": notifVal,
		"deduplicated": dedup,
		"schedule":     sc,
	})
}

func writeScheduleErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, schedule.ErrNotFound):
		WriteError(w, http.StatusNotFound, "not_found", err.Error())
	case errors.Is(err, schedule.ErrValidation):
		WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
	default:
		WriteError(w, http.StatusInternalServerError, "schedule_error", err.Error())
	}
}
