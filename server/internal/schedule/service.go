package schedule

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"dinglin/server/internal/domain"
	"dinglin/server/internal/notify"
	"dinglin/server/internal/push"
	"dinglin/server/internal/store"
)

var (
	ErrNotFound   = errors.New("schedule not found")
	ErrValidation = errors.New("validation error")
)

type CreateInput struct {
	SourceID             *string
	SourceNotificationID *string
	Kind                 string
	Title                string
	Body                 string
	Priority             string
	ScheduleType         string
	FireAt               *time.Time
	CronExpr             string
	Timezone             string
	DurationSec          int
	SnoozeMinutes        int
	SoundProfile         string
	Vibrate              *bool
	Enabled              *bool
	AutoStart            bool
}

type UpdateInput struct {
	Title         *string
	Body          *string
	Priority      *string
	FireAt        *time.Time
	CronExpr      *string
	Timezone      *string
	DurationSec   *int
	SnoozeMinutes *int
	SoundProfile  *string
	Vibrate       *bool
	Enabled       *bool
}

type ListFilter struct {
	Kind        string
	SourceID    string
	EnabledOnly bool
}

type Service struct {
	store      *store.Store
	notifySvc  *notify.Service
	dispatcher *push.Dispatcher
}

func NewService(st *store.Store, notifySvc *notify.Service, dispatcher *push.Dispatcher) *Service {
	return &Service{
		store:      st,
		notifySvc:  notifySvc,
		dispatcher: dispatcher,
	}
}

func (s *Service) Create(ctx context.Context, in CreateInput) (domain.Schedule, error) {
	in.Title = strings.TrimSpace(in.Title)
	if in.Title == "" {
		return domain.Schedule{}, fmt.Errorf("%w: title is required", ErrValidation)
	}
	if !domain.ValidScheduleKind(in.Kind) {
		return domain.Schedule{}, fmt.Errorf("%w: invalid kind %q", ErrValidation, in.Kind)
	}
	if in.Priority == "" {
		if in.Kind == domain.ScheduleKindAlarm {
			in.Priority = domain.PriorityCritical
		} else {
			in.Priority = domain.PriorityNormal
		}
	}
	if !domain.ValidPriority(in.Priority) {
		return domain.Schedule{}, fmt.Errorf("%w: invalid priority %q", ErrValidation, in.Priority)
	}
	if in.Kind == domain.ScheduleKindCountdown {
		in.ScheduleType = domain.ScheduleTypeDuration
	}
	if !domain.ValidScheduleType(in.ScheduleType) {
		return domain.Schedule{}, fmt.Errorf("%w: invalid schedule_type %q", ErrValidation, in.ScheduleType)
	}
	if in.Timezone == "" {
		in.Timezone = "UTC"
	}
	if _, err := time.LoadLocation(in.Timezone); err != nil {
		return domain.Schedule{}, fmt.Errorf("%w: invalid timezone %q", ErrValidation, in.Timezone)
	}
	if in.SnoozeMinutes <= 0 {
		in.SnoozeMinutes = 10
	}
	if in.SoundProfile == "" {
		in.SoundProfile = "default"
	}
	enabled := true
	if in.Enabled != nil {
		enabled = *in.Enabled
	}
	vibrate := true
	if in.Vibrate != nil {
		vibrate = *in.Vibrate
	}

	now := time.Now().UTC()
	sched := domain.Schedule{
		ID:                   domain.NewID(),
		SourceID:             in.SourceID,
		SourceNotificationID: in.SourceNotificationID,
		Kind:                 in.Kind,
		Title:                in.Title,
		Body:                 in.Body,
		Priority:             in.Priority,
		ScheduleType:         in.ScheduleType,
		FireAt:               in.FireAt,
		CronExpr:             strings.TrimSpace(in.CronExpr),
		Timezone:             in.Timezone,
		DurationSec:          in.DurationSec,
		RemainingSec:         in.DurationSec,
		State:                domain.ScheduleStateActive,
		SnoozeMinutes:        in.SnoozeMinutes,
		SoundProfile:         in.SoundProfile,
		Vibrate:              vibrate,
		Enabled:              enabled,
		Version:              1,
		CreatedAt:            now,
		UpdatedAt:            now,
	}

	if sched.ScheduleType == domain.ScheduleTypeDuration {
		if sched.DurationSec <= 0 {
			return domain.Schedule{}, fmt.Errorf("%w: duration_sec must be positive", ErrValidation)
		}
		if in.AutoStart || enabled {
			t := now.Add(time.Duration(sched.DurationSec) * time.Second)
			sched.TargetAt = &t
			sched.State = domain.ScheduleStateActive
		} else {
			sched.State = domain.ScheduleStatePaused
		}
	}

	nextFire, err := ComputeNextFire(sched, now)
	if err != nil {
		return domain.Schedule{}, fmt.Errorf("%w: %v", ErrValidation, err)
	}
	sched.NextFireAt = nextFire

	tx, err := s.store.DB.BeginTx(ctx, nil)
	if err != nil {
		return domain.Schedule{}, err
	}
	defer func() { _ = tx.Rollback() }()

	_, err = tx.ExecContext(ctx, `
		INSERT INTO schedules (
			id, seq, source_id, source_notification_id, kind, title, body, priority, schedule_type,
			fire_at, cron_expr, timezone, duration_sec, target_at, remaining_sec, state,
			snooze_minutes, sound_profile, vibrate, enabled, next_fire_at, version, created_at, updated_at
		) VALUES (?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		sched.ID, sched.SourceID, sched.SourceNotificationID, sched.Kind, sched.Title, sched.Body,
		sched.Priority, sched.ScheduleType, store.NullableUnix(sched.FireAt), sched.CronExpr, sched.Timezone,
		sched.DurationSec, store.NullableUnix(sched.TargetAt), sched.RemainingSec, sched.State,
		sched.SnoozeMinutes, sched.SoundProfile, store.BoolToInt(sched.Vibrate), store.BoolToInt(sched.Enabled),
		store.NullableUnix(sched.NextFireAt), sched.Version, now.Unix(), now.Unix(),
	)
	if err != nil {
		return domain.Schedule{}, err
	}

	seq, payloadRaw, err := emitScheduleEventTx(ctx, tx, "schedule.upsert", &sched, now)
	if err != nil {
		return domain.Schedule{}, err
	}
	if err := tx.Commit(); err != nil {
		return domain.Schedule{}, err
	}

	s.broadcast(ctx, seq, "schedule.upsert", sched.ID, sched.Priority, sched.Title, payloadRaw)
	return sched, nil
}

func (s *Service) GetByID(ctx context.Context, id string) (domain.Schedule, error) {
	row := s.store.DB.QueryRowContext(ctx, selectScheduleSQL+` WHERE id = ? AND deleted_at IS NULL`, id)
	sched, err := scanSchedule(row)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Schedule{}, ErrNotFound
	}
	return sched, err
}

func (s *Service) List(ctx context.Context, f ListFilter) ([]domain.Schedule, error) {
	where := []string{`deleted_at IS NULL`}
	var args []any
	if f.Kind != "" {
		where = append(where, `kind = ?`)
		args = append(args, f.Kind)
	}
	if f.SourceID != "" {
		where = append(where, `source_id = ?`)
		args = append(args, f.SourceID)
	}
	if f.EnabledOnly {
		where = append(where, `enabled = 1`)
	}
	q := selectScheduleSQL + " WHERE " + strings.Join(where, " AND ") + " ORDER BY created_at DESC"
	rows, err := s.store.DB.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]domain.Schedule, 0)
	for rows.Next() {
		sc, err := scanSchedule(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, sc)
	}
	return out, nil
}

func (s *Service) Update(ctx context.Context, id string, in UpdateInput) (domain.Schedule, error) {
	sched, err := s.GetByID(ctx, id)
	if err != nil {
		return domain.Schedule{}, err
	}
	if in.Title != nil {
		t := strings.TrimSpace(*in.Title)
		if t == "" {
			return domain.Schedule{}, fmt.Errorf("%w: title cannot be empty", ErrValidation)
		}
		sched.Title = t
	}
	if in.Body != nil {
		sched.Body = *in.Body
	}
	if in.Priority != nil {
		if !domain.ValidPriority(*in.Priority) {
			return domain.Schedule{}, fmt.Errorf("%w: invalid priority", ErrValidation)
		}
		sched.Priority = *in.Priority
	}
	if in.FireAt != nil {
		t := in.FireAt.UTC()
		sched.FireAt = &t
	}
	if in.CronExpr != nil {
		sched.CronExpr = strings.TrimSpace(*in.CronExpr)
	}
	if in.Timezone != nil {
		if _, err := time.LoadLocation(*in.Timezone); err != nil {
			return domain.Schedule{}, fmt.Errorf("%w: invalid timezone", ErrValidation)
		}
		sched.Timezone = *in.Timezone
	}
	if in.DurationSec != nil && *in.DurationSec > 0 {
		sched.DurationSec = *in.DurationSec
		if sched.State == domain.ScheduleStatePaused {
			sched.RemainingSec = *in.DurationSec
		}
	}
	if in.SnoozeMinutes != nil && *in.SnoozeMinutes > 0 {
		sched.SnoozeMinutes = *in.SnoozeMinutes
	}
	if in.SoundProfile != nil {
		sched.SoundProfile = *in.SoundProfile
	}
	if in.Vibrate != nil {
		sched.Vibrate = *in.Vibrate
	}
	if in.Enabled != nil {
		sched.Enabled = *in.Enabled
		if sched.Enabled && sched.State == domain.ScheduleStateCompleted {
			sched.State = domain.ScheduleStateActive
		}
	}

	now := time.Now().UTC()
	nextFire, err := ComputeNextFire(sched, now)
	if err != nil {
		return domain.Schedule{}, fmt.Errorf("%w: %v", ErrValidation, err)
	}
	sched.NextFireAt = nextFire
	return s.persistUpdate(ctx, sched, now)
}

func (s *Service) Toggle(ctx context.Context, id string, enabled *bool) (domain.Schedule, error) {
	sched, err := s.GetByID(ctx, id)
	if err != nil {
		return domain.Schedule{}, err
	}
	if enabled != nil {
		sched.Enabled = *enabled
	} else {
		sched.Enabled = !sched.Enabled
	}
	if sched.Enabled && (sched.State == domain.ScheduleStateCompleted || sched.State == domain.ScheduleStateCancelled) {
		sched.State = domain.ScheduleStateActive
	}
	now := time.Now().UTC()
	nextFire, err := ComputeNextFire(sched, now)
	if err != nil {
		return domain.Schedule{}, fmt.Errorf("%w: %v", ErrValidation, err)
	}
	sched.NextFireAt = nextFire
	return s.persistUpdate(ctx, sched, now)
}

func (s *Service) Snooze(ctx context.Context, id string, minutes int) (domain.Schedule, error) {
	sched, err := s.GetByID(ctx, id)
	if err != nil {
		return domain.Schedule{}, err
	}
	if minutes <= 0 {
		minutes = sched.SnoozeMinutes
	}
	if minutes <= 0 {
		minutes = 10
	}
	now := time.Now().UTC()
	next := now.Add(time.Duration(minutes) * time.Second * 60)
	sched.State = domain.ScheduleStateActive
	sched.Enabled = true
	sched.NextFireAt = &next
	if sched.ScheduleType == domain.ScheduleTypeOnce {
		sched.FireAt = &next
	}
	return s.persistUpdate(ctx, sched, now)
}

func (s *Service) Dismiss(ctx context.Context, id string) (domain.Schedule, error) {
	sched, err := s.GetByID(ctx, id)
	if err != nil {
		return domain.Schedule{}, err
	}
	now := time.Now().UTC()
	if sched.ScheduleType == domain.ScheduleTypeCron && sched.Enabled {
		sched.State = domain.ScheduleStateActive
		nextFire, err := ComputeNextFire(sched, now)
		if err == nil {
			sched.NextFireAt = nextFire
		}
	} else {
		sched.State = domain.ScheduleStateCompleted
		sched.Enabled = false
		sched.NextFireAt = nil
	}
	return s.persistUpdate(ctx, sched, now)
}

func (s *Service) CountdownAction(ctx context.Context, id, action string) (domain.Schedule, error) {
	sched, err := s.GetByID(ctx, id)
	if err != nil {
		return domain.Schedule{}, err
	}
	if sched.Kind != domain.ScheduleKindCountdown {
		return domain.Schedule{}, fmt.Errorf("%w: schedule is not a countdown", ErrValidation)
	}
	now := time.Now().UTC()
	switch action {
	case "start":
		rem := sched.DurationSec
		if rem <= 0 {
			return domain.Schedule{}, fmt.Errorf("%w: invalid duration_sec", ErrValidation)
		}
		target := now.Add(time.Duration(rem) * time.Second)
		sched.State = domain.ScheduleStateActive
		sched.Enabled = true
		sched.RemainingSec = rem
		sched.TargetAt = &target
		sched.NextFireAt = &target
	case "pause":
		if sched.State == domain.ScheduleStateActive && sched.TargetAt != nil {
			rem := int(time.Until(*sched.TargetAt).Seconds())
			if rem < 0 {
				rem = 0
			}
			sched.RemainingSec = rem
		}
		sched.State = domain.ScheduleStatePaused
		sched.TargetAt = nil
		sched.NextFireAt = nil
	case "resume":
		rem := sched.RemainingSec
		if rem <= 0 {
			rem = sched.DurationSec
		}
		target := now.Add(time.Duration(rem) * time.Second)
		sched.State = domain.ScheduleStateActive
		sched.Enabled = true
		sched.TargetAt = &target
		sched.NextFireAt = &target
	case "reset":
		sched.State = domain.ScheduleStatePaused
		sched.RemainingSec = sched.DurationSec
		sched.TargetAt = nil
		sched.NextFireAt = nil
	case "cancel":
		sched.State = domain.ScheduleStateCancelled
		sched.Enabled = false
		sched.RemainingSec = 0
		sched.TargetAt = nil
		sched.NextFireAt = nil
	default:
		return domain.Schedule{}, fmt.Errorf("%w: unsupported countdown action %q", ErrValidation, action)
	}
	return s.persistUpdate(ctx, sched, now)
}

func (s *Service) Delete(ctx context.Context, id string) error {
	now := time.Now().UTC()
	tx, err := s.store.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.ExecContext(ctx, `
		UPDATE schedules SET deleted_at = ?, enabled = 0, next_fire_at = NULL, version = version + 1, updated_at = ?
		WHERE id = ? AND deleted_at IS NULL`, now.Unix(), now.Unix(), id)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	payload := map[string]any{"id": id, "deleted_at": now}
	seq, payloadRaw, err := store.AppendSyncEventTx(ctx, tx, "schedule.delete", id, payload, now)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE schedules SET seq = ? WHERE id = ?`, seq, id); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	s.broadcast(ctx, seq, "schedule.delete", id, "", "", payloadRaw)
	return nil
}

// MarkTriggered records a locally-fired occurrence idempotently and rolls the schedule forward.
func (s *Service) MarkTriggered(ctx context.Context, id, occurrenceKey string, firedAt time.Time) (domain.Notification, bool, domain.Schedule, error) {
	sched, err := s.GetByID(ctx, id)
	if err != nil {
		return domain.Notification{}, false, domain.Schedule{}, err
	}
	if firedAt.IsZero() {
		firedAt = time.Now().UTC()
	}
	if occurrenceKey == "" {
		fireTS := firedAt.UTC().Unix()
		if sched.NextFireAt != nil {
			fireTS = sched.NextFireAt.UTC().Unix()
		}
		occurrenceKey = fmt.Sprintf("sched:%s:%d", sched.ID, fireTS)
	}
	return s.triggerSchedule(ctx, sched, occurrenceKey, firedAt.UTC())
}

// ProcessDue scans all due schedules (scheduled_notification, alarm, countdown) and triggers them idempotently.
func (s *Service) ProcessDue(ctx context.Context, now time.Time) (int, error) {
	rows, err := s.store.DB.QueryContext(ctx, selectScheduleSQL+`
		WHERE deleted_at IS NULL AND enabled = 1 AND state = 'active'
		  AND next_fire_at IS NOT NULL AND next_fire_at <= ?
		ORDER BY next_fire_at ASC`, now.UTC().Unix())
	if err != nil {
		return 0, err
	}
	var due []domain.Schedule
	for rows.Next() {
		sc, err := scanSchedule(rows)
		if err == nil {
			due = append(due, sc)
		}
	}
	_ = rows.Close()

	triggered := 0
	for _, sc := range due {
		occKey := fmt.Sprintf("sched:%s:%d", sc.ID, sc.NextFireAt.UTC().Unix())
		if _, _, _, err := s.triggerSchedule(ctx, sc, occKey, now.UTC()); err == nil {
			triggered++
		}
	}
	return triggered, nil
}

// StartScanner starts the 10-second background due-schedule scanner.
func (s *Service) StartScanner(ctx context.Context, interval time.Duration) {
	if interval <= 0 {
		interval = 10 * time.Second
	}
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				_, _ = s.ProcessDue(ctx, time.Now().UTC())
			}
		}
	}()
}

func (s *Service) triggerSchedule(ctx context.Context, sched domain.Schedule, occurrenceKey string, now time.Time) (domain.Notification, bool, domain.Schedule, error) {
	in := notify.CreateInput{
		SourceID:      sched.SourceID,
		OccurrenceKey: occurrenceKey,
		Priority:      sched.Priority,
		Title:         sched.Title,
		Body:          sched.Body,
		Category:      sched.Kind,
		Metadata: map[string]any{
			"schedule_id":   sched.ID,
			"schedule_kind": sched.Kind,
		},
	}

	// Inherit actions & callback_url from original notification when firing a snoozed notification.
	if sched.SourceNotificationID != nil && *sched.SourceNotificationID != "" {
		if orig, err := s.notifySvc.GetByID(ctx, *sched.SourceNotificationID); err == nil {
			in.Actions = orig.Actions
			in.CallbackURL = orig.CallbackURL
			if in.SourceID == nil {
				in.SourceID = orig.SourceID
			}
			if orig.Category != "" {
				in.Category = orig.Category
			}
			in.Metadata["source_notification_id"] = orig.ID
		}
	}

	notif, dedup, err := s.notifySvc.Create(ctx, in)
	if err != nil {
		return domain.Notification{}, false, sched, err
	}

	// Advance recurring schedule or complete one-shot/countdown.
	if sched.ScheduleType == domain.ScheduleTypeCron && sched.Enabled {
		base := now
		if sched.NextFireAt != nil && sched.NextFireAt.After(base) {
			base = *sched.NextFireAt
		}
		nextFire, err := ComputeNextFire(sched, base)
		if err == nil {
			sched.NextFireAt = nextFire
		}
	} else {
		sched.State = domain.ScheduleStateCompleted
		sched.Enabled = false
		sched.NextFireAt = nil
		if sched.Kind == domain.ScheduleKindCountdown {
			sched.RemainingSec = 0
			sched.TargetAt = nil
		}
	}
	updated, err := s.persistUpdate(ctx, sched, now)
	if err != nil {
		return notif, dedup, sched, err
	}
	return notif, dedup, updated, nil
}

func (s *Service) persistUpdate(ctx context.Context, sched domain.Schedule, now time.Time) (domain.Schedule, error) {
	sched.Version++
	sched.UpdatedAt = now

	tx, err := s.store.DB.BeginTx(ctx, nil)
	if err != nil {
		return domain.Schedule{}, err
	}
	defer func() { _ = tx.Rollback() }()

	_, err = tx.ExecContext(ctx, `
		UPDATE schedules SET
			title = ?, body = ?, priority = ?, fire_at = ?, cron_expr = ?, timezone = ?,
			duration_sec = ?, target_at = ?, remaining_sec = ?, state = ?, snooze_minutes = ?,
			sound_profile = ?, vibrate = ?, enabled = ?, next_fire_at = ?, version = ?, updated_at = ?
		WHERE id = ? AND deleted_at IS NULL`,
		sched.Title, sched.Body, sched.Priority, store.NullableUnix(sched.FireAt), sched.CronExpr, sched.Timezone,
		sched.DurationSec, store.NullableUnix(sched.TargetAt), sched.RemainingSec, sched.State, sched.SnoozeMinutes,
		sched.SoundProfile, store.BoolToInt(sched.Vibrate), store.BoolToInt(sched.Enabled),
		store.NullableUnix(sched.NextFireAt), sched.Version, now.Unix(), sched.ID,
	)
	if err != nil {
		return domain.Schedule{}, err
	}

	seq, payloadRaw, err := emitScheduleEventTx(ctx, tx, "schedule.upsert", &sched, now)
	if err != nil {
		return domain.Schedule{}, err
	}
	if err := tx.Commit(); err != nil {
		return domain.Schedule{}, err
	}

	s.broadcast(ctx, seq, "schedule.upsert", sched.ID, sched.Priority, sched.Title, payloadRaw)
	return sched, nil
}

func emitScheduleEventTx(ctx context.Context, tx *sql.Tx, eventType string, sched *domain.Schedule, now time.Time) (int64, json.RawMessage, error) {
	seq, payloadRaw, err := store.AppendSyncEventTx(ctx, tx, eventType, sched.ID, sched, now)
	if err != nil {
		return 0, nil, err
	}
	sched.Seq = seq
	if _, err := tx.ExecContext(ctx, `UPDATE schedules SET seq = ? WHERE id = ?`, seq, sched.ID); err != nil {
		return 0, nil, err
	}
	if updatedRaw, err := json.Marshal(sched); err == nil {
		payloadRaw = updatedRaw
		_, _ = tx.ExecContext(ctx, `UPDATE sync_events SET payload_json = ? WHERE seq = ?`, string(updatedRaw), seq)
	}
	return seq, payloadRaw, nil
}

func (s *Service) broadcast(ctx context.Context, seq int64, eventType, entityID, priority, title string, data json.RawMessage) {
	if s.dispatcher != nil {
		s.dispatcher.Broadcast(ctx, push.EventMessage{
			Seq:       seq,
			EventType: eventType,
			EntityID:  entityID,
			Priority:  priority,
			Title:     title,
			Data:      data,
		})
	}
}

const selectScheduleSQL = `
	SELECT id, seq, source_id, source_notification_id, kind, title, body, priority, schedule_type,
		fire_at, cron_expr, timezone, duration_sec, target_at, remaining_sec, state,
		snooze_minutes, sound_profile, vibrate, enabled, next_fire_at, version, deleted_at, created_at, updated_at
	FROM schedules`

type rowScanner interface {
	Scan(dest ...any) error
}

func scanSchedule(r rowScanner) (domain.Schedule, error) {
	var (
		sc            domain.Schedule
		sourceID      sql.NullString
		sourceNotifID sql.NullString
		fireAt        sql.NullInt64
		targetAt      sql.NullInt64
		vibrate       int
		enabled       int
		nextFireAt    sql.NullInt64
		deletedAt     sql.NullInt64
		createdAt     int64
		updatedAt     int64
	)
	if err := r.Scan(
		&sc.ID, &sc.Seq, &sourceID, &sourceNotifID, &sc.Kind, &sc.Title, &sc.Body, &sc.Priority, &sc.ScheduleType,
		&fireAt, &sc.CronExpr, &sc.Timezone, &sc.DurationSec, &targetAt, &sc.RemainingSec, &sc.State,
		&sc.SnoozeMinutes, &sc.SoundProfile, &vibrate, &enabled, &nextFireAt, &sc.Version, &deletedAt, &createdAt, &updatedAt,
	); err != nil {
		return domain.Schedule{}, err
	}
	if sourceID.Valid {
		v := sourceID.String
		sc.SourceID = &v
	}
	if sourceNotifID.Valid {
		v := sourceNotifID.String
		sc.SourceNotificationID = &v
	}
	sc.FireAt = store.FromNullUnix(fireAt)
	sc.TargetAt = store.FromNullUnix(targetAt)
	sc.Vibrate = vibrate != 0
	sc.Enabled = enabled != 0
	sc.NextFireAt = store.FromNullUnix(nextFireAt)
	sc.DeletedAt = store.FromNullUnix(deletedAt)
	sc.CreatedAt = time.Unix(createdAt, 0).UTC()
	sc.UpdatedAt = time.Unix(updatedAt, 0).UTC()
	return sc, nil
}
