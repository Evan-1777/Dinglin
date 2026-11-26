package push

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"dinglin/server/internal/domain"
)

const (
	defaultFCMEndpoint = "https://fcm.googleapis.com"
	defaultTokenURI    = "https://oauth2.googleapis.com/token"
	fcmScope           = "https://www.googleapis.com/auth/firebase.messaging"
)

type serviceAccountCreds struct {
	ProjectID   string `json:"project_id"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
}

// FCMTransport sends high-priority data-only messages via FCM HTTP v1 using Go stdlib only.
type FCMTransport struct {
	creds      serviceAccountCreds
	privateKey *rsa.PrivateKey
	endpoint   string
	client     *http.Client

	mu          sync.Mutex
	accessToken string
	tokenExpiry time.Time
}

// NewFCMTransportFromFile loads a Google service account JSON file.
func NewFCMTransportFromFile(path string) (*FCMTransport, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read fcm credentials: %w", err)
	}
	return NewFCMTransportFromJSON(raw, defaultFCMEndpoint, nil)
}

// NewFCMTransportFromJSON parses credentials JSON and allows overriding endpoint/client for tests.
func NewFCMTransportFromJSON(raw []byte, endpoint string, httpClient *http.Client) (*FCMTransport, error) {
	var creds serviceAccountCreds
	if err := json.Unmarshal(raw, &creds); err != nil {
		return nil, fmt.Errorf("parse fcm credentials: %w", err)
	}
	if creds.ProjectID == "" || creds.ClientEmail == "" || creds.PrivateKey == "" {
		return nil, errors.New("fcm credentials missing project_id, client_email, or private_key")
	}
	if creds.TokenURI == "" {
		creds.TokenURI = defaultTokenURI
	}
	key, err := parseRSAPrivateKey(creds.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("parse fcm private key: %w", err)
	}
	if endpoint == "" {
		endpoint = defaultFCMEndpoint
	}
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 10 * time.Second}
	}
	return &FCMTransport{
		creds:      creds,
		privateKey: key,
		endpoint:   strings.TrimRight(endpoint, "/"),
		client:     httpClient,
	}, nil
}

func (f *FCMTransport) Send(ctx context.Context, device domain.Device, msg EventMessage) error {
	if device.FCMToken == "" {
		return nil
	}
	accessToken, err := f.getAccessToken(ctx)
	if err != nil {
		return fmt.Errorf("fcm oauth token: %w", err)
	}

	payload := map[string]any{
		"message": map[string]any{
			"token": device.FCMToken,
			"android": map[string]any{
				"priority": "HIGH",
			},
			"data": map[string]string{
				"event_type": msg.EventType,
				"entity_id":  msg.EntityID,
				"priority":   msg.Priority,
				"title":      msg.Title,
				"seq":        strconv.FormatInt(msg.Seq, 10),
			},
		},
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	reqURL := fmt.Sprintf("%s/v1/projects/%s/messages:send", f.endpoint, f.creds.ProjectID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, reqURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := f.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	bodyStr := string(respBody)
	if strings.Contains(bodyStr, "UNREGISTERED") || strings.Contains(bodyStr, "INVALID_ARGUMENT") {
		return fmt.Errorf("%w: status=%d body=%s", ErrInvalidFCMToken, resp.StatusCode, bodyStr)
	}
	return fmt.Errorf("fcm send failed: status=%d body=%s", resp.StatusCode, bodyStr)
}

func (f *FCMTransport) getAccessToken(ctx context.Context) (string, error) {
	f.mu.Lock()
	if f.accessToken != "" && time.Now().UTC().Add(60*time.Second).Before(f.tokenExpiry) {
		tok := f.accessToken
		f.mu.Unlock()
		return tok, nil
	}
	f.mu.Unlock()

	assertion, err := f.signJWT(time.Now().UTC())
	if err != nil {
		return "", err
	}
	form := url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {assertion},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, f.creds.TokenURI, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := f.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return "", fmt.Errorf("token endpoint status %d: %s", resp.StatusCode, string(raw))
	}

	var tr struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tr); err != nil {
		return "", err
	}
	if tr.AccessToken == "" {
		return "", errors.New("empty access_token in oauth response")
	}
	if tr.ExpiresIn <= 0 {
		tr.ExpiresIn = 3600
	}

	f.mu.Lock()
	f.accessToken = tr.AccessToken
	f.tokenExpiry = time.Now().UTC().Add(time.Duration(tr.ExpiresIn) * time.Second)
	f.mu.Unlock()
	return tr.AccessToken, nil
}

func (f *FCMTransport) signJWT(now time.Time) (string, error) {
	header, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT"})
	claims, _ := json.Marshal(map[string]any{
		"iss":   f.creds.ClientEmail,
		"scope": fcmScope,
		"aud":   f.creds.TokenURI,
		"iat":   now.Unix(),
		"exp":   now.Add(time.Hour).Unix(),
	})

	enc := base64.RawURLEncoding
	signingInput := enc.EncodeToString(header) + "." + enc.EncodeToString(claims)
	hash := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, f.privateKey, crypto.SHA256, hash[:])
	if err != nil {
		return "", err
	}
	return signingInput + "." + enc.EncodeToString(sig), nil
}

func parseRSAPrivateKey(pemStr string) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode([]byte(pemStr))
	if block == nil {
		return nil, errors.New("invalid PEM block")
	}
	if key, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		rsaKey, ok := key.(*rsa.PrivateKey)
		if !ok {
			return nil, errors.New("PKCS8 key is not RSA")
		}
		return rsaKey, nil
	}
	return x509.ParsePKCS1PrivateKey(block.Bytes)
}
