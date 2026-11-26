package schedule

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"dinglin/server/internal/domain"
	"dinglin/server/internal/notify"
	"dinglin/server/internal/store"
)

func TestCronNextAcrossTimezones(t *testing.T) {
	// Friday 2026-11-27 08:00 Asia/Shanghai -> next "30 7 * * 1-5" should be Monday 2026-11-30 07:30 Asia/Shanghai
	shanghai, _ := time.LoadLocation("Asia/Shanghai")
	now := time.Date(2026, 11, 27, 8, 0, 0, 0, shanghai)

	sched := domain.Schedule{
		Kind:         domain.ScheduleKindAlarm,
		ScheduleType: domain.ScheduleTypeCron,
		CronExpr:     "30 7 * * 1-5",
		Timezone:     "Asia/Shanghai",
		Enabled:      true,
		State:        domain.ScheduleStateActive,
	}
	next, err := ComputeNextFire(sched, now)
	if err != nil || next == nil {
		t.Fatalf("ComputeNextFire failed: next=%v err=%v", next, err)
	}
	gotLocal := next.In(shanghai)
	wantLocal := time.Date(2026, 11, 30, 7, 30, 0, 0, shanghai)
	if !gotLocal.Equal(wantLocal) {
		t.Fatalf("got %v, want %v", gotLocal, wantLocal)
	}
}

func TestScheduleDueAllKindsAndTriggeredDedup(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "sched.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer st.Close()
	ctx := context.Background()
	if err := st.Migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	notifySvc := notify.NewService(st, nil)
	svc := NewService(st, notifySvc, nil)

	past := time.Now().UTC().Add(-2 * time.Minute)

	// 1. One-shot scheduled_notification
	sn, err := svc.Create(ctx, CreateInput{
		Kind:         domain.ScheduleKindNotification,
		Title:        "Reminder",
		ScheduleType: domain.ScheduleTypeOnce,
		FireAt:       &past,
	})
	if err != nil {
		t.Fatalf("create scheduled_notification: %v", err)
	}

	// 2. Recurring alarm (set next_fire_at in past to trigger scan)
	alarm, err := svc.Create(ctx, CreateInput{
		Kind:         domain.ScheduleKindAlarm,
		Title:        "Morning Alarm",
		ScheduleType: domain.ScheduleTypeCron,
		CronExpr:     "0 7 * * *",
		Timezone:     "UTC",
	})
	if err != nil {
		t.Fatalf("create alarm: %v", err)
	}
	_, _ = st.DB.ExecContext(ctx, `UPDATE schedules SET next_fire_at = ? WHERE id = ?`, past.Unix(), alarm.ID)

	// 3. Countdown pause/resume + due trigger
	cd, err := svc.Create(ctx, CreateInput{
		Kind:        domain.ScheduleKindCountdown,
		Title:       "Tea Timer",
		DurationSec: 120,
		AutoStart:   true,
	})
	if err != nil {
		t.Fatalf("create countdown: %v", err)
	}
	paused, err := svc.CountdownAction(ctx, cd.ID, "pause")
	if err != nil || paused.State != domain.ScheduleStatePaused || paused.RemainingSec <= 0 {
		t.Fatalf("pause countdown unexpected: %+v err=%v", paused, err)
	}
	resumed, err := svc.CountdownAction(ctx, cd.ID, "resume")
	if err != nil || resumed.State != domain.ScheduleStateActive || resumed.TargetAt == nil {
		t.Fatalf("resume countdown unexpected: %+v err=%v", resumed, err)
	}
	_, _ = st.DB.ExecContext(ctx, `UPDATE schedules SET next_fire_at = ? WHERE id = ?`, past.Unix(), cd.ID)

	// Trigger alarm locally via MarkTriggered first; ProcessDue must not duplicate it!
	occKey := "sched:" + alarm.ID + ":" + time.Unix(past.Unix(), 0).UTC().Format("20060102150405")
	_, dedup1, updatedAlarm, err := svc.MarkTriggered(ctx, alarm.ID, occKey, time.Now().UTC())
	if err != nil || dedup1 {
		t.Fatalf("first MarkTriggered failed: dedup=%v err=%v", dedup1, err)
	}
	if updatedAlarm.NextFireAt == nil || !updatedAlarm.NextFireAt.After(time.Now().UTC()) {
		t.Fatalf("expected recurring alarm next_fire_at rolled forward, got %v", updatedAlarm.NextFireAt)
	}
	// Repeat same occurrence_key -> deduplicated
	_, dedup2, _, err := svc.MarkTriggered(ctx, alarm.ID, occKey, time.Now().UTC())
	if err != nil || !dedup2 {
		t.Fatalf("expected deduplicated=true on repeat occurrence_key, got dedup=%v err=%v", dedup2, err)
	}

	// ProcessDue should fire sn + cd (2 schedules), and skip alarm which already rolled forward
	n, err := svc.ProcessDue(ctx, time.Now().UTC())
	if err != nil || n != 2 {
		t.Fatalf("expected 2 due schedules triggered, got %d (err=%v)", n, err)
	}

	// Verify one-shot & countdown are now completed
	snAfter, _ := svc.GetByID(ctx, sn.ID)
	cdAfter, _ := svc.GetByID(ctx, cd.ID)
	if snAfter.State != domain.ScheduleStateCompleted || cdAfter.State != domain.ScheduleStateCompleted {
		t.Fatalf("expected completed states, got sn=%s cd=%s", snAfter.State, cdAfter.State)
	}

	// Verify total notifications == 3 (alarm + sn + cd)
	notifs, err := notifySvc.List(ctx, notify.ListFilter{IncludeExpired: true})
	if err != nil || len(notifs) != 3 {
		t.Fatalf("expected 3 notifications, got %d (err=%v)", len(notifs), err)
	}
}
