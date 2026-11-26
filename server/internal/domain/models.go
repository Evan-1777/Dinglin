package domain

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"time"
)

const (
	SourceKindWebhook = "webhook"
	SourceKindAgent   = "agent"

	PlatformAndroid = "android"
	PlatformWeb     = "web"

	PushModeFCM = "fcm"
	PushModeWS  = "ws"
	PushModeWeb = "web"

	PrioritySilent   = "silent"
	PriorityNormal   = "normal"
	PriorityCritical = "critical"

	NotificationStatusUnread    = "unread"
	NotificationStatusRead      = "read"
	NotificationStatusAcked     = "acked"
	NotificationStatusSnoozed   = "snoozed"
	NotificationStatusDismissed = "dismissed"

	ScheduleKindNotification = "scheduled_notification"
	ScheduleKindAlarm        = "alarm"
	ScheduleKindCountdown    = "countdown"

	ScheduleTypeOnce     = "once"
	ScheduleTypeCron     = "cron"
	ScheduleTypeDuration = "duration"

	ScheduleStateActive    = "active"
	ScheduleStatePaused    = "paused"
	ScheduleStateRinging   = "ringing"
	ScheduleStateCompleted = "completed"
	ScheduleStateCancelled = "cancelled"

	CallbackStatusPending   = "pending"
	CallbackStatusDelivered = "delivered"
	CallbackStatusFailed    = "failed"
)

// NewID generates a 32-character cryptographically random hex ID.
func NewID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("crypto/rand failed: " + err.Error())
	}
	return hex.EncodeToString(b[:])
}

type Source struct {
	ID             string    `json:"id"`
	Slug           string    `json:"slug"`
	Name           string    `json:"name"`
	Kind           string    `json:"kind"`
	Color          string    `json:"color"`
	TokenHash      string    `json:"-"`
	TokenPrefix    string    `json:"token_prefix"`
	CallbackURL    string    `json:"callback_url"`
	CallbackSecret string    `json:"-"`
	Enabled        bool      `json:"enabled"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

type Device struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	Platform   string     `json:"platform"`
	TokenHash  string     `json:"-"`
	FCMToken   string     `json:"fcm_token,omitempty"`
	HasGMS     bool       `json:"has_gms"`
	PushMode   string     `json:"push_mode"`
	Online     bool       `json:"online"`
	LastSeenAt *time.Time `json:"last_seen_at,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
}

type QuickAction struct {
	ID      string         `json:"id"`
	Label   string         `json:"label"`
	Style   string         `json:"style,omitempty"`
	Payload map[string]any `json:"payload,omitempty"`
}

type Notification struct {
	ID             string         `json:"id"`
	Seq            int64          `json:"seq"`
	SourceID       *string        `json:"source_id,omitempty"`
	IdempotencyKey *string        `json:"idempotency_key,omitempty"`
	OccurrenceKey  *string        `json:"occurrence_key,omitempty"`
	Priority       string         `json:"priority"`
	Title          string         `json:"title"`
	Body           string         `json:"body"`
	Category       string         `json:"category,omitempty"`
	Actions        []QuickAction  `json:"actions,omitempty"`
	Metadata       map[string]any `json:"metadata,omitempty"`
	CallbackURL    string         `json:"callback_url,omitempty"`
	Status         string         `json:"status"`
	SnoozedUntil   *time.Time     `json:"snoozed_until,omitempty"`
	ExpiresAt      *time.Time     `json:"expires_at,omitempty"`
	CreatedAt      time.Time      `json:"created_at"`
	UpdatedAt      time.Time      `json:"updated_at"`
}

type Receipt struct {
	ID             string         `json:"id"`
	NotificationID string         `json:"notification_id"`
	DeviceID       *string        `json:"device_id,omitempty"`
	ActionID       string         `json:"action_id"`
	ActionLabel    string         `json:"action_label,omitempty"`
	Payload        map[string]any `json:"payload,omitempty"`
	CreatedAt      time.Time      `json:"created_at"`
}

type Schedule struct {
	ID                   string     `json:"id"`
	Seq                  int64      `json:"seq"`
	SourceID             *string    `json:"source_id,omitempty"`
	SourceNotificationID *string    `json:"source_notification_id,omitempty"`
	Kind                 string     `json:"kind"`
	Title                string     `json:"title"`
	Body                 string     `json:"body,omitempty"`
	Priority             string     `json:"priority"`
	ScheduleType         string     `json:"schedule_type"`
	FireAt               *time.Time `json:"fire_at,omitempty"`
	CronExpr             string     `json:"cron_expr,omitempty"`
	Timezone             string     `json:"timezone"`
	DurationSec          int        `json:"duration_sec,omitempty"`
	TargetAt             *time.Time `json:"target_at,omitempty"`
	RemainingSec         int        `json:"remaining_sec,omitempty"`
	State                string     `json:"state"`
	SnoozeMinutes        int        `json:"snooze_minutes"`
	SoundProfile         string     `json:"sound_profile,omitempty"`
	Vibrate              bool       `json:"vibrate"`
	Enabled              bool       `json:"enabled"`
	NextFireAt           *time.Time `json:"next_fire_at,omitempty"`
	Version              int        `json:"version"`
	DeletedAt            *time.Time `json:"deleted_at,omitempty"`
	CreatedAt            time.Time  `json:"created_at"`
	UpdatedAt            time.Time  `json:"updated_at"`
}

type SyncEvent struct {
	Seq       int64           `json:"seq"`
	EventType string          `json:"event_type"`
	EntityID  string          `json:"entity_id"`
	Payload   json.RawMessage `json:"payload"`
	CreatedAt time.Time       `json:"created_at"`
}

type CallbackJob struct {
	ID             string          `json:"id"`
	NotificationID string          `json:"notification_id"`
	ReceiptID      string          `json:"receipt_id"`
	TargetURL      string          `json:"target_url"`
	SigningSecret  string          `json:"-"`
	Payload        json.RawMessage `json:"payload"`
	Status         string          `json:"status"`
	Attempts       int             `json:"attempts"`
	NextAttemptAt  time.Time       `json:"next_attempt_at"`
	LastHTTPStatus int             `json:"last_http_status,omitempty"`
	LastError      string          `json:"last_error,omitempty"`
	CreatedAt      time.Time       `json:"created_at"`
	UpdatedAt      time.Time       `json:"updated_at"`
}

type Settings struct {
	DNDEnabled           bool   `json:"dnd_enabled"`
	DNDStart             string `json:"dnd_start"`
	DNDEnd               string `json:"dnd_end"`
	DefaultSnoozeMinutes int    `json:"default_snooze_minutes"`
	RetentionDays        int    `json:"retention_days"`
}

func DefaultSettings(retentionDays int) Settings {
	if retentionDays <= 0 {
		retentionDays = 30
	}
	return Settings{
		DNDEnabled:           false,
		DNDStart:             "23:00",
		DNDEnd:               "07:00",
		DefaultSnoozeMinutes: 10,
		RetentionDays:        retentionDays,
	}
}

func ValidSourceKind(v string) bool {
	return v == SourceKindWebhook || v == SourceKindAgent
}

func ValidPlatform(v string) bool {
	return v == PlatformAndroid || v == PlatformWeb
}

func ValidPriority(v string) bool {
	return v == PrioritySilent || v == PriorityNormal || v == PriorityCritical
}

func ValidNotificationStatus(v string) bool {
	switch v {
	case NotificationStatusUnread, NotificationStatusRead, NotificationStatusAcked, NotificationStatusSnoozed, NotificationStatusDismissed:
		return true
	default:
		return false
	}
}

func ValidScheduleKind(v string) bool {
	return v == ScheduleKindNotification || v == ScheduleKindAlarm || v == ScheduleKindCountdown
}

func ValidScheduleType(v string) bool {
	return v == ScheduleTypeOnce || v == ScheduleTypeCron || v == ScheduleTypeDuration
}

func ValidScheduleState(v string) bool {
	switch v {
	case ScheduleStateActive, ScheduleStatePaused, ScheduleStateRinging, ScheduleStateCompleted, ScheduleStateCancelled:
		return true
	default:
		return false
	}
}
