package push

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"dinglin/server/internal/store"

	"github.com/coder/websocket"
)

const (
	// MasterSessionKey groups WebSocket connections authenticated via the owner Master Key.
	MasterSessionKey = "__master__"

	WSHeartbeatSec   = 30
	WSReadTimeout    = 45 * time.Second
	WSWriteTimeout   = 10 * time.Second
	wsOutboundBuffer = 64
)

type wsClient struct {
	deviceID string
	conn     *websocket.Conn
	send     chan []byte
}

// WSHub manages active WebSocket connections with fixed 30s heartbeat / 45s read timeout.
type WSHub struct {
	store *store.Store
	mu    sync.RWMutex
	conns map[string]map[*wsClient]struct{}
}

func NewWSHub(st *store.Store) *WSHub {
	return &WSHub{
		store: st,
		conns: make(map[string]map[*wsClient]struct{}),
	}
}

func (h *WSHub) IsOnline(deviceID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.conns[deviceID]) > 0
}

// SendToDevice enqueues an event frame for all active connections of a device.
func (h *WSHub) SendToDevice(deviceID string, msg EventMessage) bool {
	frame, err := json.Marshal(map[string]any{
		"type":       "event",
		"seq":        msg.Seq,
		"event_type": msg.EventType,
		"entity_id":  msg.EntityID,
		"data":       msg.Data,
	})
	if err != nil {
		return false
	}

	h.mu.RLock()
	clients := h.conns[deviceID]
	if len(clients) == 0 {
		h.mu.RUnlock()
		return false
	}
	targets := make([]*wsClient, 0, len(clients))
	for c := range clients {
		targets = append(targets, c)
	}
	h.mu.RUnlock()

	delivered := false
	for _, c := range targets {
		select {
		case c.send <- frame:
			delivered = true
		default:
			// Slow consumer; will catch up via /api/v1/sync on reconnect.
		}
	}
	return delivered
}

// ServeWS upgrades an authenticated HTTP request to WebSocket and blocks until disconnection.
func (h *WSHub) ServeWS(w http.ResponseWriter, r *http.Request, deviceID string) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: true,
	})
	if err != nil {
		return
	}
	if deviceID == "" {
		deviceID = MasterSessionKey
	}

	client := &wsClient{
		deviceID: deviceID,
		conn:     conn,
		send:     make(chan []byte, wsOutboundBuffer),
	}
	h.register(client)
	defer h.unregister(client)

	h.touchDevice(r.Context(), deviceID)

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	// Writer goroutine
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-ctx.Done():
				return
			case msg, ok := <-client.send:
				if !ok {
					return
				}
				wctx, wcancel := context.WithTimeout(ctx, WSWriteTimeout)
				err := conn.Write(wctx, websocket.MessageText, msg)
				wcancel()
				if err != nil {
					cancel()
					return
				}
			}
		}
	}()

	// Reader loop with fixed 45s read timeout
	for {
		rctx, rcancel := context.WithTimeout(ctx, WSReadTimeout)
		_, data, err := conn.Read(rctx)
		rcancel()
		if err != nil {
			break
		}

		var incoming struct {
			Type string `json:"type"`
			Seq  int64  `json:"seq"`
		}
		if json.Unmarshal(data, &incoming) != nil {
			continue
		}
		switch incoming.Type {
		case "ping":
			pong, _ := json.Marshal(map[string]any{"type": "pong", "ts": time.Now().UTC().Unix()})
			select {
			case client.send <- pong:
			default:
			}
			h.touchDevice(ctx, deviceID)
		case "ack_seq":
			h.touchDevice(ctx, deviceID)
		}
	}

	cancel()
	_ = conn.Close(websocket.StatusNormalClosure, "")
	wg.Wait()
	h.touchDevice(context.Background(), deviceID)
}

func (h *WSHub) register(c *wsClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.conns[c.deviceID] == nil {
		h.conns[c.deviceID] = make(map[*wsClient]struct{})
	}
	h.conns[c.deviceID][c] = struct{}{}
}

func (h *WSHub) unregister(c *wsClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if set := h.conns[c.deviceID]; set != nil {
		delete(set, c)
		if len(set) == 0 {
			delete(h.conns, c.deviceID)
		}
	}
}

func (h *WSHub) touchDevice(ctx context.Context, deviceID string) {
	if h.store == nil || deviceID == "" || deviceID == MasterSessionKey {
		return
	}
	_, _ = h.store.DB.ExecContext(ctx, `UPDATE devices SET last_seen_at = ? WHERE id = ?`, time.Now().UTC().Unix(), deviceID)
}
