CREATE TABLE IF NOT EXISTS sources (
    id TEXT PRIMARY KEY,
    slug TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('webhook', 'agent')),
    color TEXT NOT NULL DEFAULT '#007AFF',
    token_hash TEXT NOT NULL UNIQUE,
    token_prefix TEXT NOT NULL,
    callback_url TEXT NOT NULL DEFAULT '',
    callback_secret TEXT NOT NULL DEFAULT '',
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    platform TEXT NOT NULL CHECK (platform IN ('android', 'web')),
    token_hash TEXT NOT NULL UNIQUE,
    fcm_token TEXT NOT NULL DEFAULT '',
    has_gms INTEGER NOT NULL DEFAULT 0,
    push_mode TEXT NOT NULL DEFAULT 'ws' CHECK (push_mode IN ('fcm', 'ws', 'web')),
    last_seen_at INTEGER,
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sync_events (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    event_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sync_events_created_at ON sync_events(created_at);

CREATE TABLE IF NOT EXISTS notifications (
    id TEXT PRIMARY KEY,
    seq INTEGER NOT NULL DEFAULT 0,
    source_id TEXT REFERENCES sources(id) ON DELETE SET NULL,
    idempotency_key TEXT,
    occurrence_key TEXT,
    priority TEXT NOT NULL DEFAULT 'normal' CHECK (priority IN ('silent', 'normal', 'critical')),
    title TEXT NOT NULL,
    body TEXT NOT NULL DEFAULT '',
    category TEXT NOT NULL DEFAULT '',
    actions_json TEXT NOT NULL DEFAULT '[]',
    metadata_json TEXT NOT NULL DEFAULT '{}',
    callback_url TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'unread' CHECK (status IN ('unread', 'read', 'acked', 'snoozed', 'dismissed')),
    snoozed_until INTEGER,
    expires_at INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_notifications_source_idempotency
    ON notifications(source_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL AND idempotency_key != '';

CREATE UNIQUE INDEX IF NOT EXISTS idx_notifications_occurrence
    ON notifications(occurrence_key)
    WHERE occurrence_key IS NOT NULL AND occurrence_key != '';

CREATE INDEX IF NOT EXISTS idx_notifications_seq ON notifications(seq DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_status ON notifications(status);
CREATE INDEX IF NOT EXISTS idx_notifications_source_id ON notifications(source_id);

CREATE TABLE IF NOT EXISTS receipts (
    id TEXT PRIMARY KEY,
    notification_id TEXT NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
    device_id TEXT REFERENCES devices(id) ON DELETE SET NULL,
    action_id TEXT NOT NULL,
    action_label TEXT NOT NULL DEFAULT '',
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_receipts_notification_id ON receipts(notification_id, created_at);

CREATE TABLE IF NOT EXISTS schedules (
    id TEXT PRIMARY KEY,
    seq INTEGER NOT NULL DEFAULT 0,
    source_id TEXT REFERENCES sources(id) ON DELETE SET NULL,
    source_notification_id TEXT REFERENCES notifications(id) ON DELETE SET NULL,
    kind TEXT NOT NULL CHECK (kind IN ('scheduled_notification', 'alarm', 'countdown')),
    title TEXT NOT NULL,
    body TEXT NOT NULL DEFAULT '',
    priority TEXT NOT NULL DEFAULT 'normal' CHECK (priority IN ('silent', 'normal', 'critical')),
    schedule_type TEXT NOT NULL CHECK (schedule_type IN ('once', 'cron', 'duration')),
    fire_at INTEGER,
    cron_expr TEXT NOT NULL DEFAULT '',
    timezone TEXT NOT NULL DEFAULT 'UTC',
    duration_sec INTEGER NOT NULL DEFAULT 0,
    target_at INTEGER,
    remaining_sec INTEGER NOT NULL DEFAULT 0,
    state TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'paused', 'ringing', 'completed', 'cancelled')),
    snooze_minutes INTEGER NOT NULL DEFAULT 10,
    sound_profile TEXT NOT NULL DEFAULT 'default',
    vibrate INTEGER NOT NULL DEFAULT 1,
    enabled INTEGER NOT NULL DEFAULT 1,
    next_fire_at INTEGER,
    version INTEGER NOT NULL DEFAULT 1,
    deleted_at INTEGER,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_schedules_due ON schedules(enabled, state, next_fire_at) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_schedules_source_id ON schedules(source_id);

CREATE TABLE IF NOT EXISTS callback_jobs (
    id TEXT PRIMARY KEY,
    notification_id TEXT NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
    receipt_id TEXT NOT NULL REFERENCES receipts(id) ON DELETE CASCADE,
    target_url TEXT NOT NULL,
    signing_secret TEXT NOT NULL DEFAULT '',
    payload_json TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'delivered', 'failed')),
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL,
    last_http_status INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_callback_jobs_pending ON callback_jobs(status, next_attempt_at);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value_json TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);
