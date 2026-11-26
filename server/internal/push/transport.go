package push

import (
	"context"
	"encoding/json"
	"errors"
	"log"

	"dinglin/server/internal/domain"
	"dinglin/server/internal/store"
)

// ErrInvalidFCMToken indicates the device's FCM registration token is no longer valid.
var ErrInvalidFCMToken = errors.New("invalid or unregistered fcm token")

// EventMessage is the normalized push payload routed over WS or FCM.
type EventMessage struct {
	Seq       int64           `json:"seq"`
	EventType string          `json:"event_type"`
	EntityID  string          `json:"entity_id"`
	Priority  string          `json:"priority,omitempty"`
	Title     string          `json:"title,omitempty"`
	Data      json.RawMessage `json:"data"`
}

// Transport delivers a push message to a single offline device.
type Transport interface {
	Send(ctx context.Context, device domain.Device, msg EventMessage) error
}

// Dispatcher routes events to online WebSocket clients and falls back to optional FCM for offline devices.
type Dispatcher struct {
	store *store.Store
	hub   *WSHub
	fcm   Transport
}

func NewDispatcher(st *store.Store, hub *WSHub, fcm Transport) *Dispatcher {
	return &Dispatcher{store: st, hub: hub, fcm: fcm}
}

// Broadcast delivers an event to all connected WS sessions and wakes offline FCM devices.
func (d *Dispatcher) Broadcast(ctx context.Context, msg EventMessage) {
	if d == nil {
		return
	}
	if d.hub != nil {
		// Always deliver to master-key sessions (e.g. Web admin console).
		d.hub.SendToDevice(MasterSessionKey, msg)
	}

	rows, err := d.store.DB.QueryContext(ctx, `SELECT id, name, platform, fcm_token, has_gms, push_mode FROM devices`)
	if err != nil {
		log.Printf("push broadcast query devices: %v", err)
		return
	}
	var devices []domain.Device
	for rows.Next() {
		var dev domain.Device
		var hasGMS int
		if err := rows.Scan(&dev.ID, &dev.Name, &dev.Platform, &dev.FCMToken, &hasGMS, &dev.PushMode); err == nil {
			dev.HasGMS = hasGMS != 0
			devices = append(devices, dev)
		}
	}
	_ = rows.Close()

	for _, dev := range devices {
		_, _ = d.deliverToDevice(ctx, dev, msg)
	}
}

// SendToDevice sends a message to a specific device and returns the channel used ("ws", "fcm", or "offline").
func (d *Dispatcher) SendToDevice(ctx context.Context, deviceID string, msg EventMessage) (string, error) {
	var dev domain.Device
	var hasGMS int
	err := d.store.DB.QueryRowContext(ctx,
		`SELECT id, name, platform, fcm_token, has_gms, push_mode FROM devices WHERE id = ?`,
		deviceID,
	).Scan(&dev.ID, &dev.Name, &dev.Platform, &dev.FCMToken, &hasGMS, &dev.PushMode)
	if err != nil {
		return "", err
	}
	dev.HasGMS = hasGMS != 0
	return d.deliverToDevice(ctx, dev, msg)
}

func (d *Dispatcher) deliverToDevice(ctx context.Context, dev domain.Device, msg EventMessage) (string, error) {
	if d.hub != nil && d.hub.SendToDevice(dev.ID, msg) {
		return "ws", nil
	}
	if d.fcm != nil && dev.FCMToken != "" {
		if err := d.fcm.Send(ctx, dev, msg); err != nil {
			if errors.Is(err, ErrInvalidFCMToken) {
				_, _ = d.store.DB.ExecContext(ctx,
					`UPDATE devices SET fcm_token = '', push_mode = CASE WHEN platform = 'web' THEN 'web' ELSE 'ws' END WHERE id = ?`,
					dev.ID,
				)
			}
			return "fcm_error", err
		}
		return "fcm", nil
	}
	return "offline", nil
}
