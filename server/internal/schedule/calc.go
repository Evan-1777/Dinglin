package schedule

import (
	"fmt"
	"time"

	"dinglin/server/internal/domain"
)

// ComputeNextFire calculates the next UTC fire time for a schedule relative to `now`.
func ComputeNextFire(s domain.Schedule, now time.Time) (*time.Time, error) {
	if !s.Enabled || s.State == domain.ScheduleStateCompleted || s.State == domain.ScheduleStateCancelled {
		return nil, nil
	}

	switch s.ScheduleType {
	case domain.ScheduleTypeOnce:
		if s.FireAt == nil {
			return nil, fmt.Errorf("fire_at is required for once schedule")
		}
		t := s.FireAt.UTC()
		return &t, nil

	case domain.ScheduleTypeCron:
		spec, err := ParseCron(s.CronExpr)
		if err != nil {
			return nil, err
		}
		tz := s.Timezone
		if tz == "" {
			tz = "UTC"
		}
		loc, err := time.LoadLocation(tz)
		if err != nil {
			return nil, fmt.Errorf("invalid timezone %q: %w", tz, err)
		}
		nextLocal, err := spec.Next(now.In(loc))
		if err != nil {
			return nil, err
		}
		nextUTC := nextLocal.UTC()
		return &nextUTC, nil

	case domain.ScheduleTypeDuration:
		if s.State == domain.ScheduleStateActive && s.TargetAt != nil {
			t := s.TargetAt.UTC()
			return &t, nil
		}
		return nil, nil

	default:
		return nil, fmt.Errorf("unsupported schedule_type %q", s.ScheduleType)
	}
}
