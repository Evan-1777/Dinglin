package mcp

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// RunStdio bridges newline-delimited JSON-RPC messages over stdin/stdout to a remote Dinglin /mcp endpoint.
func RunStdio(ctx context.Context, args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("mcp-stdio", flag.ContinueOnError)
	fs.SetOutput(stderr)

	serverURL := os.Getenv("DINGLIN_SERVER_URL")
	token := os.Getenv("DINGLIN_MCP_TOKEN")

	fs.StringVar(&serverURL, "server", serverURL, "Dinglin MCP endpoint URL (e.g. https://dinglin.example.com/mcp)")
	fs.StringVar(&token, "token", token, "Dinglin Agent Bearer token")

	if err := fs.Parse(args); err != nil {
		return err
	}
	serverURL = strings.TrimSpace(serverURL)
	token = strings.TrimSpace(token)
	if serverURL == "" {
		return errors.New("missing --server or DINGLIN_SERVER_URL")
	}
	if token == "" {
		return errors.New("missing --token or DINGLIN_MCP_TOKEN")
	}

	client := &http.Client{Timeout: 30 * time.Second}
	scanner := bufio.NewScanner(stdin)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)

	var sessionID string
	for scanner.Scan() {
		select {
		case <-ctx.Done():
			return nil
		default:
		}
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		req, err := http.NewRequestWithContext(ctx, http.MethodPost, serverURL, bytes.NewReader([]byte(line)))
		if err != nil {
			fmt.Fprintf(stderr, "mcp-stdio: build request failed: %v\n", err)
			continue
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json")
		req.Header.Set("Authorization", "Bearer "+token)
		if sessionID != "" {
			req.Header.Set(SessionHeader, sessionID)
		}

		resp, err := client.Do(req)
		if err != nil {
			fmt.Fprintf(stderr, "mcp-stdio: request error: %v\n", err)
			continue
		}
		if sid := strings.TrimSpace(resp.Header.Get(SessionHeader)); sid != "" {
			sessionID = sid
		}
		body, readErr := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if readErr != nil {
			fmt.Fprintf(stderr, "mcp-stdio: read response error: %v\n", readErr)
			continue
		}
		if resp.StatusCode == http.StatusAccepted {
			continue
		}
		trimmed := bytes.TrimSpace(body)
		if len(trimmed) == 0 {
			if resp.StatusCode >= 400 {
				fmt.Fprintf(stderr, "mcp-stdio: upstream HTTP %d\n", resp.StatusCode)
			}
			continue
		}
		if _, err := stdout.Write(append(trimmed, '\n')); err != nil {
			return err
		}
	}
	if err := scanner.Err(); err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	return nil
}
