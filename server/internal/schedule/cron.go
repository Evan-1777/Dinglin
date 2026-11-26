package schedule

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// CronSpec represents a parsed standard 5-field cron expression (min hour dom month dow).
type CronSpec struct {
	minute   uint64
	hour     uint64
	dom      uint64
	month    uint64
	dow      uint64
	domWild  bool
	dowWild  bool
}

// ParseCron parses a standard 5-field cron expression: "min hour dom month dow".
func ParseCron(expr string) (CronSpec, error) {
	fields := strings.Fields(strings.TrimSpace(expr))
	if len(fields) != 5 {
		return CronSpec{}, fmt.Errorf("cron expression must have 5 fields, got %d", len(fields))
	}

	minMask, _, err := parseField(fields[0], 0, 59, false)
	if err != nil {
		return CronSpec{}, fmt.Errorf("minute field: %w", err)
	}
	hourMask, _, err := parseField(fields[1], 0, 23, false)
	if err != nil {
		return CronSpec{}, fmt.Errorf("hour field: %w", err)
	}
	domMask, domWild, err := parseField(fields[2], 1, 31, false)
	if err != nil {
		return CronSpec{}, fmt.Errorf("day-of-month field: %w", err)
	}
	monthMask, _, err := parseField(fields[3], 1, 12, false)
	if err != nil {
		return CronSpec{}, fmt.Errorf("month field: %w", err)
	}
	dowMask, dowWild, err := parseField(fields[4], 0, 6, true)
	if err != nil {
		return CronSpec{}, fmt.Errorf("day-of-week field: %w", err)
	}

	return CronSpec{
		minute:  minMask,
		hour:    hourMask,
		dom:     domMask,
		month:   monthMask,
		dow:     dowMask,
		domWild: domWild,
		dowWild: dowWild,
	}, nil
}

// Next returns the next activation time strictly after `from`, preserving `from`'s Location.
func (c CronSpec) Next(from time.Time) (time.Time, error) {
	t := from.Truncate(time.Minute).Add(time.Minute)
	limitYear := t.Year() + 4

	for t.Year() <= limitYear {
		if c.month&(1<<uint(t.Month())) == 0 {
			t = time.Date(t.Year(), t.Month()+1, 1, 0, 0, 0, 0, t.Location())
			continue
		}
		if !c.matchDay(t) {
			t = time.Date(t.Year(), t.Month(), t.Day()+1, 0, 0, 0, 0, t.Location())
			continue
		}
		if c.hour&(1<<uint(t.Hour())) == 0 {
			t = time.Date(t.Year(), t.Month(), t.Day(), t.Hour()+1, 0, 0, 0, t.Location())
			continue
		}
		if c.minute&(1<<uint(t.Minute())) == 0 {
			t = t.Add(time.Minute)
			continue
		}
		return t, nil
	}
	return time.Time{}, fmt.Errorf("no matching cron activation within 4 years")
}

func (c CronSpec) matchDay(t time.Time) bool {
	domMatch := c.dom&(1<<uint(t.Day())) != 0
	dowMatch := c.dow&(1<<uint(t.Weekday())) != 0
	if !c.domWild && !c.dowWild {
		return domMatch || dowMatch
	}
	return domMatch && dowMatch
}

func parseField(field string, minVal, maxVal int, allowSevenAsZero bool) (uint64, bool, error) {
	if field == "*" {
		return bitRange(minVal, maxVal, 1), true, nil
	}
	var mask uint64
	parts := strings.Split(field, ",")
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			return 0, false, fmt.Errorf("empty segment in %q", field)
		}
		step := 1
		rangePart := part
		if strings.Contains(part, "/") {
			halves := strings.Split(part, "/")
			if len(halves) != 2 {
				return 0, false, fmt.Errorf("invalid step syntax %q", part)
			}
			rangePart = halves[0]
			s, err := strconv.Atoi(halves[1])
			if err != nil || s <= 0 {
				return 0, false, fmt.Errorf("invalid step %q", halves[1])
			}
			step = s
		}

		var start, end int
		switch {
		case rangePart == "*":
			start, end = minVal, maxVal
		case strings.Contains(rangePart, "-"):
			bounds := strings.Split(rangePart, "-")
			if len(bounds) != 2 {
				return 0, false, fmt.Errorf("invalid range %q", rangePart)
			}
			a, err := parseNum(bounds[0], minVal, maxVal, allowSevenAsZero)
			if err != nil {
				return 0, false, err
			}
			b, err := parseNum(bounds[1], minVal, maxVal, allowSevenAsZero)
			if err != nil {
				return 0, false, err
			}
			if a > b {
				return 0, false, fmt.Errorf("range start %d > end %d", a, b)
			}
			start, end = a, b
		default:
			v, err := parseNum(rangePart, minVal, maxVal, allowSevenAsZero)
			if err != nil {
				return 0, false, err
			}
			start, end = v, v
			if strings.Contains(part, "/") {
				end = maxVal
			}
		}

		mask |= bitRange(start, end, step)
	}
	if mask == 0 {
		return 0, false, fmt.Errorf("empty bitmask for %q", field)
	}
	return mask, false, nil
}

func parseNum(s string, minVal, maxVal int, allowSevenAsZero bool) (int, error) {
	v, err := strconv.Atoi(s)
	if err != nil {
		return 0, fmt.Errorf("invalid number %q", s)
	}
	if allowSevenAsZero && v == 7 {
		v = 0
	}
	if v < minVal || v > maxVal {
		return 0, fmt.Errorf("value %d out of range [%d,%d]", v, minVal, maxVal)
	}
	return v, nil
}

func bitRange(start, end, step int) uint64 {
	var mask uint64
	for v := start; v <= end; v += step {
		mask |= 1 << uint(v)
	}
	return mask
}
