package config

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
)

const Version = "0.1.0"

// Config holds runtime configuration for the Dinglin server.
type Config struct {
	Addr               string
	DBPath             string
	MasterKey          string
	PublicURL          string
	FCMCredentialsFile string
	RetentionDays      int
	WebDistDir         string
}

// Load parses configuration from environment variables with optional CLI flag overrides.
func Load(args []string) (Config, error) {
	cfg := Config{
		Addr:               envOrDefault("DINGLIN_ADDR", ":8080"),
		DBPath:             envOrDefault("DINGLIN_DB_PATH", "./data/dinglin.db"),
		MasterKey:          strings.TrimSpace(os.Getenv("DINGLIN_MASTER_KEY")),
		PublicURL:          strings.TrimRight(strings.TrimSpace(os.Getenv("DINGLIN_PUBLIC_URL")), "/"),
		FCMCredentialsFile: strings.TrimSpace(os.Getenv("DINGLIN_FCM_CREDENTIALS_FILE")),
		RetentionDays:      30,
		WebDistDir:         strings.TrimSpace(os.Getenv("DINGLIN_WEB_DIST_DIR")),
	}

	if raw := strings.TrimSpace(os.Getenv("DINGLIN_RETENTION_DAYS")); raw != "" {
		v, err := strconv.Atoi(raw)
		if err != nil || v <= 0 {
			return Config{}, fmt.Errorf("invalid DINGLIN_RETENTION_DAYS %q: must be a positive integer", raw)
		}
		cfg.RetentionDays = v
	}

	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.StringVar(&cfg.Addr, "addr", cfg.Addr, "HTTP listen address")
	fs.StringVar(&cfg.DBPath, "db", cfg.DBPath, "SQLite database file path")
	fs.StringVar(&cfg.MasterKey, "master-key", cfg.MasterKey, "Required owner master key")
	fs.StringVar(&cfg.PublicURL, "public-url", cfg.PublicURL, "Public base URL")
	fs.StringVar(&cfg.FCMCredentialsFile, "fcm-credentials", cfg.FCMCredentialsFile, "Optional FCM service account JSON path")
	fs.IntVar(&cfg.RetentionDays, "retention-days", cfg.RetentionDays, "Notification retention days")
	fs.StringVar(&cfg.WebDistDir, "web-dist", cfg.WebDistDir, "Optional Flutter Web build directory")

	if err := fs.Parse(args); err != nil {
		return Config{}, err
	}

	cfg.MasterKey = strings.TrimSpace(cfg.MasterKey)
	cfg.PublicURL = strings.TrimRight(strings.TrimSpace(cfg.PublicURL), "/")

	if cfg.MasterKey == "" {
		return Config{}, errors.New("DINGLIN_MASTER_KEY is required")
	}
	if cfg.RetentionDays <= 0 {
		return Config{}, errors.New("retention-days must be positive")
	}
	return cfg, nil
}

func envOrDefault(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}
