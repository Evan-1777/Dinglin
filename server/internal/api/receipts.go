package api

import (
	"errors"
	"net/http"

	"dinglin/server/internal/auth"
	"dinglin/server/internal/callback"
	"dinglin/server/internal/notify"
)

func (s *Server) RegisterReceiptRoutes(cbSvc *callback.Service, notifySvc *notify.Service) {
	s.RegisterRoutes(func(mux *http.ServeMux) {
		mux.Handle("POST /api/v1/notifications/{id}/receipt", s.auth.RequireOwner(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleSubmitReceipt(w, r, cbSvc)
		})))
		mux.Handle("GET /api/v1/notifications/{id}/receipts", s.auth.RequireOwnerOrSource(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s.handleListReceipts(w, r, cbSvc, notifySvc)
		})))
	})
}

func (s *Server) handleSubmitReceipt(w http.ResponseWriter, r *http.Request, cbSvc *callback.Service) {
	id := r.PathValue("id")
	var req struct {
		ActionID      string         `json:"action_id"`
		SnoozeMinutes int            `json:"snooze_minutes"`
		Payload       map[string]any `json:"payload"`
	}
	if err := DecodeJSON(r, &req); err != nil {
		WriteError(w, http.StatusBadRequest, "invalid_json", err.Error())
		return
	}

	var devID *string
	if p, ok := auth.FromContext(r.Context()); ok && p.Device != nil {
		v := p.Device.ID
		devID = &v
	}

	receipt, notif, err := cbSvc.SubmitReceipt(r.Context(), callback.ReceiptInput{
		NotificationID: id,
		DeviceID:       devID,
		ActionID:       req.ActionID,
		SnoozeMinutes:  req.SnoozeMinutes,
		Payload:        req.Payload,
	})
	if err != nil {
		if errors.Is(err, notify.ErrNotFound) {
			WriteError(w, http.StatusNotFound, "not_found", err.Error())
			return
		}
		WriteError(w, http.StatusBadRequest, "receipt_error", err.Error())
		return
	}
	WriteJSON(w, http.StatusCreated, map[string]any{
		"receipt":      receipt,
		"notification": notif,
	})
}

func (s *Server) handleListReceipts(w http.ResponseWriter, r *http.Request, cbSvc *callback.Service, notifySvc *notify.Service) {
	id := r.PathValue("id")
	notif, err := notifySvc.GetByID(r.Context(), id)
	if err != nil {
		if errors.Is(err, notify.ErrNotFound) {
			WriteError(w, http.StatusNotFound, "not_found", "notification not found")
			return
		}
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}

	// Enforce source isolation when called with a Source token.
	if p, ok := auth.FromContext(r.Context()); ok && !p.IsOwner() {
		if p.Source == nil || notif.SourceID == nil || *notif.SourceID != p.Source.ID {
			WriteError(w, http.StatusForbidden, "forbidden", "source cannot access receipts of another source")
			return
		}
	}

	receipts, err := cbSvc.ListReceipts(r.Context(), id)
	if err != nil {
		WriteError(w, http.StatusInternalServerError, "db_error", err.Error())
		return
	}
	WriteJSON(w, http.StatusOK, map[string]any{"receipts": receipts})
}
