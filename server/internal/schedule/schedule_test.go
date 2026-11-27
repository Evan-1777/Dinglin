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

	// Trigger alarm locally via MarkTriggered first -> enters ringing without writing notifications!
	occKey := "sched:" + alarm.ID + ":" + time.Unix(past.Unix(), 0).UTC().Format("20060102150405")
	notif1, dedup1, updatedAlarm, err := svc.MarkTriggered(ctx, alarm.ID, occKey, time.Now().UTC())
	if err != nil || dedup1 {
		t.Fatalf("first MarkTriggered failed: dedup=%v err=%v", dedup1, err)
	}
	if notif1.ID != "" {
		t.Fatalf("expected alarm trigger to produce no notification, got %+v", notif1)
	}
	if updatedAlarm.State != domain.ScheduleStateRinging || updatedAlarm.NextFireAt != nil {
		t.Fatalf("expected alarm state=ringing and next_fire_at=nil, got state=%q next=%v", updatedAlarm.State, updatedAlarm.NextFireAt)
	}
	// Repeat trigger while ringing -> deduplicated
	_, dedup2, _, err := svc.MarkTriggered(ctx, alarm.ID, occKey, time.Now().UTC())
	if err != nil || !dedup2 {
		t.Fatalf("expected deduplicated=true on repeat alarm trigger, got dedup=%v err=%v", dedup2, err)
	}

	// ProcessDue should fire sn + cd (2 schedules), and skip ringing alarm
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

	// Verify total notifications == 2 (sn + cd only; alarm must not create notifications)
	notifs, err := notifySvc.List(ctx, notify.ListFilter{IncludeExpired: true})
	if err != nil || len(notifs) != 2 {
		t.Fatalf("expected 2 notifications (no alarm notification), got %d (err=%v)", len(notifs), err)
	}

	// Snooze ringing alarm -> returns to active with future next_fire_at
	snoozed, err := svc.Snooze(ctx, alarm.ID, 5)
	if err != nil || snoozed.State != domain.ScheduleStateActive || snoozed.NextFireAt == nil || !snoozed.NextFireAt.After(time.Now().UTC()) {
		t.Fatalf("snooze unexpected: %+v err=%v", snoozed, err)
	}
	// Late /triggered from earlier occurrence (before snoozed NextFireAt) must be deduplicated
	_, lateDedup, _, err := svc.MarkTriggered(ctx, alarm.ID, occKey, past)
	if err != nil || !lateDedup {
		t.Fatalf("expected late alarm trigger to be deduplicated, got dedup=%v err=%v", lateDedup, err)
	}

	// Re-trigger alarm into ringing, then dismiss cron -> active with next cron fire
	_, _ = st.DB.ExecContext(ctx, `UPDATE schedules SET next_fire_at = ? WHERE id = ?`, past.Unix(), alarm.ID)
	if _, dedup, scRing, err := svc.MarkTriggered(ctx, alarm.ID, "", time.Now().UTC()); err != nil || dedup || scRing.State != domain.ScheduleStateRinging {
		t.Fatalf("re-trigger failed: dedup=%v state=%q err=%v", dedup, scRing.State, err)
	}
	dismissedCron, err := svc.Dismiss(ctx, alarm.ID)
	if err != nil || dismissedCron.State != domain.ScheduleStateActive || dismissedCron.NextFireAt == nil || !dismissedCron.NextFireAt.After(time.Now().UTC()) {
		t.Fatalf("dismiss cron unexpected: %+v err=%v", dismissedCron, err)
	}

	// Ringing cron alarm toggled off -> active (never paused) with next_fire_at=nil, and toggling back on restores active + next_fire_at
	_, _ = st.DB.ExecContext(ctx, `UPDATE schedules SET next_fire_at = ? WHERE id = ?`, past.Unix(), alarm.ID)
	_, _, _, _ = svc.MarkTriggered(ctx, alarm.ID, "", time.Now().UTC())
	fVal, tVal := false, true
	toggledOff, err := svc.Toggle(ctx, alarm.ID, &fVal)
	if err != nil || toggledOff.State != domain.ScheduleStateActive || toggledOff.Enabled || toggledOff.NextFireAt != nil {
		t.Fatalf("toggle off ringing cron unexpected: %+v err=%v", toggledOff, err)
	}
	toggledOn, err := svc.Toggle(ctx, alarm.ID, &tVal)
	if err != nil || toggledOn.State != domain.ScheduleStateActive || !toggledOn.Enabled || toggledOn.NextFireAt == nil {
		t.Fatalf("toggle on cron unexpected: %+v err=%v", toggledOn, err)
	}

	// Ringing once alarm: Update exits ringing, and Dismiss marks completed + enabled=false
	onceAlarm, err := svc.Create(ctx, CreateInput{
		Kind:         domain.ScheduleKindAlarm,
		Title:        "One-shot Alarm",
		ScheduleType: domain.ScheduleTypeOnce,
		FireAt:       &past,
	})
	if err != nil {
		t.Fatalf("create once alarm: %v", err)
	}
	if _, dedup, ringOnce, err := svc.MarkTriggered(ctx, onceAlarm.ID, "", time.Now().UTC()); err != nil || dedup || ringOnce.State != domain.ScheduleStateRinging {
		t.Fatalf("once alarm trigger unexpected: dedup=%v state=%q err=%v", dedup, ringOnce.State, err)
	}
	futureFire := time.Now().UTC().Add(1 * time.Hour)
	editedOnce, err := svc.Update(ctx, onceAlarm.ID, UpdateInput{FireAt: &futureFire})
	if err != nil || editedOnce.State != domain.ScheduleStateActive || editedOnce.NextFireAt == nil {
		t.Fatalf("update ringing once alarm unexpected: %+v err=%v", editedOnce, err)
	}
	_, _ = st.DB.ExecContext(ctx, `UPDATE schedules SET next_fire_at = ? WHERE id = ?`, past.Unix(), onceAlarm.ID)
	_, _, _, _ = svc.MarkTriggered(ctx, onceAlarm.ID, "", time.Now().UTC())
	dismissedOnce, err := svc.Dismiss(ctx, onceAlarm.ID)
	if err != nil || dismissedOnce.State != domain.ScheduleStateCompleted || dismissedOnce.Enabled {
		t.Fatalf("dismiss once alarm unexpected: %+v err=%v", dismissedOnce, err)
	}
}
