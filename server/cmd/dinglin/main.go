package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"dinglin/server/internal/api"
	"dinglin/server/internal/auth"
	"dinglin/server/internal/callback"
	"dinglin/server/internal/config"
	"dinglin/server/internal/notify"
	"dinglin/server/internal/push"
	"dinglin/server/internal/schedule"
	"dinglin/server/internal/store"
)

func main() {
	args := os.Args[1:]
	subcmd := "serve"
	if len(args) > 0 && args[0] != "" && args[0][0] != '-' {
		subcmd = args[0]
		args = args[1:]
	}

	switch subcmd {
	case "serve":
		if err := runServe(args); err != nil {
			fmt.Fprintf(os.Stderr, "dinglin: %v\n", err)
			os.Exit(1)
		}
	case "mcp-stdio":
		fmt.Fprintln(os.Stderr, "dinglin: mcp-stdio will be implemented in Phase 3")
		os.Exit(2)
	default:
		fmt.Fprintf(os.Stderr, "dinglin: unknown subcommand %q (supported: serve, mcp-stdio)\n", subcmd)
		os.Exit(2)
	}
}

func runServe(args []string) error {
	cfg, err := config.Load(args)
	if err != nil {
		return err
	}

	st, err := store.Open(cfg.DBPath)
	if err != nil {
		return err
	}
	defer st.Close()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if err := st.Migrate(ctx); err != nil {
		return err
	}

	var fcmTransport push.Transport
	if cfg.FCMCredentialsFile != "" {
		fcm, err := push.NewFCMTransportFromFile(cfg.FCMCredentialsFile)
		if err != nil {
			return fmt.Errorf("init fcm transport: %w", err)
		}
		fcmTransport = fcm
		log.Printf("dinglin: FCM HTTP v1 transport enabled")
	} else {
		log.Printf("dinglin: FCM credentials not configured; running in WebSocket-only push mode")
	}

	hub := push.NewWSHub(st)
	dispatcher := push.NewDispatcher(st, hub, fcmTransport)
	notifySvc := notify.NewService(st, dispatcher)
	scheduleSvc := schedule.NewService(st, notifySvc, dispatcher)
	callbackSvc := callback.NewService(st, notifySvc, scheduleSvc, dispatcher, cfg.RetentionDays)

	notifySvc.StartRetentionCleaner(ctx, cfg.RetentionDays)
	scheduleSvc.StartScanner(ctx, 10*time.Second)
	callbackSvc.StartWorker(ctx, 2*time.Second)

	authenticator := auth.New(st, cfg.MasterKey)
	srv := api.NewServer(cfg, st, authenticator)
	srv.RegisterNotificationRoutes(notifySvc)
	srv.RegisterSyncAndPushRoutes(hub, dispatcher)
	srv.RegisterScheduleRoutes(scheduleSvc)
	srv.RegisterReceiptRoutes(callbackSvc, notifySvc)

	httpSrv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Printf("dinglin server v%s listening on %s", config.Version, cfg.Addr)
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
		close(errCh)
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return httpSrv.Shutdown(shutdownCtx)
	}
}
