package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"dinglin/server/internal/domain"
	"dinglin/server/internal/store"
)

type ctxKey int

const principalKey ctxKey = 1

// Principal represents the authenticated caller attached to a request context.
type Principal struct {
	IsMaster bool
	Device   *domain.Device
	Source   *domain.Source
}

func (p Principal) IsOwner() bool {
	return p.IsMaster || p.Device != nil
}

func WithPrincipal(ctx context.Context, p Principal) context.Context {
	return context.WithValue(ctx, principalKey, p)
}

func FromContext(ctx context.Context) (Principal, bool) {
	p, ok := ctx.Value(principalKey).(Principal)
	return p, ok
}

// GenerateToken produces a random token with the given prefix, its display prefix, and SHA-256 hex digest.
func GenerateToken(prefix string) (plaintext, displayPrefix, sha256Hex string, err error) {
	var raw [24]byte
	if _, err = rand.Read(raw[:]); err != nil {
		return "", "", "", err
	}
	plaintext = prefix + base64.RawURLEncoding.EncodeToString(raw[:])
	if len(plaintext) > 12 {
		displayPrefix = plaintext[:12]
	} else {
		displayPrefix = plaintext
	}
	sha256Hex = HashToken(plaintext)
	return plaintext, displayPrefix, sha256Hex, nil
}

// HashToken computes the SHA-256 hex digest of a plaintext secret.
func HashToken(plaintext string) string {
	sum := sha256.Sum256([]byte(plaintext))
	return hex.EncodeToString(sum[:])
}

// VerifyMasterKey compares provided key against expected key in constant time.
func VerifyMasterKey(provided, expected string) bool {
	if expected == "" || len(provided) != len(expected) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) == 1
}

// ExtractToken retrieves a bearer token from Authorization header, or optionally from ?token= query param.
func ExtractToken(r *http.Request, allowQuery bool) string {
	hdr := strings.TrimSpace(r.Header.Get("Authorization"))
	if strings.HasPrefix(hdr, "Bearer ") || strings.HasPrefix(hdr, "bearer ") {
		if tok := strings.TrimSpace(hdr[7:]); tok != "" {
			return tok
		}
	}
	if allowQuery {
		if tok := strings.TrimSpace(r.URL.Query().Get("token")); tok != "" {
			return tok
		}
	}
	return ""
}

// Authenticator resolves owner (master key / device token) and source tokens.
type Authenticator struct {
	store     *store.Store
	masterKey string
}

func New(st *store.Store, masterKey string) *Authenticator {
	return &Authenticator{store: st, masterKey: masterKey}
}

func (a *Authenticator) AuthenticateOwner(ctx context.Context, token string) (Principal, error) {
	if token == "" {
		return Principal{}, ErrUnauthenticated
	}
	if VerifyMasterKey(token, a.masterKey) {
		return Principal{IsMaster: true}, nil
	}
	dev, err := a.AuthenticateDevice(ctx, token)
	if err != nil {
		return Principal{}, ErrUnauthenticated
	}
	return Principal{Device: dev}, nil
}

func (a *Authenticator) AuthenticateDevice(ctx context.Context, token string) (*domain.Device, error) {
	if token == "" {
		return nil, ErrUnauthenticated
	}
	hash := HashToken(token)
	var (
		d          domain.Device
		hasGMS     int
		lastSeenAt sql.NullInt64
		createdAt  int64
	)
	err := a.store.DB.QueryRowContext(ctx, `
		SELECT id, name, platform, token_hash, fcm_token, has_gms, push_mode, last_seen_at, created_at
		FROM devices WHERE token_hash = ?`, hash).Scan(
		&d.ID, &d.Name, &d.Platform, &d.TokenHash, &d.FCMToken, &hasGMS, &d.PushMode, &lastSeenAt, &createdAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrUnauthenticated
	}
	if err != nil {
		return nil, err
	}
	d.HasGMS = hasGMS != 0
	d.LastSeenAt = store.FromNullUnix(lastSeenAt)
	d.CreatedAt = time.Unix(createdAt, 0).UTC()
	return &d, nil
}

func (a *Authenticator) AuthenticateSource(ctx context.Context, token string) (*domain.Source, error) {
	if token == "" {
		return nil, ErrUnauthenticated
	}
	hash := HashToken(token)
	var (
		s         domain.Source
		enabled   int
		createdAt int64
		updatedAt int64
	)
	err := a.store.DB.QueryRowContext(ctx, `
		SELECT id, slug, name, kind, color, token_hash, token_prefix, callback_url, callback_secret, enabled, created_at, updated_at
		FROM sources WHERE token_hash = ?`, hash).Scan(
		&s.ID, &s.Slug, &s.Name, &s.Kind, &s.Color, &s.TokenHash, &s.TokenPrefix, &s.CallbackURL, &s.CallbackSecret, &enabled, &createdAt, &updatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrUnauthenticated
	}
	if err != nil {
		return nil, err
	}
	s.Enabled = enabled != 0
	s.CreatedAt = time.Unix(createdAt, 0).UTC()
	s.UpdatedAt = time.Unix(updatedAt, 0).UTC()
	if !s.Enabled {
		return nil, ErrForbidden
	}
	return &s, nil
}

var (
	ErrUnauthenticated = errors.New("unauthenticated")
	ErrForbidden       = errors.New("forbidden")
)

// RequireOwner accepts Master Key or any bound Device Token.
func (a *Authenticator) RequireOwner(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := ExtractToken(r, false)
		p, err := a.AuthenticateOwner(r.Context(), tok)
		if err != nil {
			writeAuthError(w, http.StatusUnauthorized, "unauthorized", "invalid or missing owner credentials")
			return
		}
		next.ServeHTTP(w, r.WithContext(WithPrincipal(r.Context(), p)))
	})
}

// RequireSource accepts an enabled Source/Agent token.
func (a *Authenticator) RequireSource(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := ExtractToken(r, false)
		src, err := a.AuthenticateSource(r.Context(), tok)
		if errors.Is(err, ErrForbidden) {
			writeAuthError(w, http.StatusForbidden, "source_disabled", "source is disabled")
			return
		}
		if err != nil {
			writeAuthError(w, http.StatusUnauthorized, "unauthorized", "invalid or missing source token")
			return
		}
		next.ServeHTTP(w, r.WithContext(WithPrincipal(r.Context(), Principal{Source: src})))
	})
}

// RequireOwnerOrSource accepts either Owner credentials or an enabled Source token.
func (a *Authenticator) RequireOwnerOrSource(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := ExtractToken(r, false)
		if tok == "" {
			writeAuthError(w, http.StatusUnauthorized, "unauthorized", "missing credentials")
			return
		}
		if p, err := a.AuthenticateOwner(r.Context(), tok); err == nil {
			next.ServeHTTP(w, r.WithContext(WithPrincipal(r.Context(), p)))
			return
		}
		src, err := a.AuthenticateSource(r.Context(), tok)
		if errors.Is(err, ErrForbidden) {
			writeAuthError(w, http.StatusForbidden, "source_disabled", "source is disabled")
			return
		}
		if err != nil {
			writeAuthError(w, http.StatusUnauthorized, "unauthorized", "invalid credentials")
			return
		}
		next.ServeHTTP(w, r.WithContext(WithPrincipal(r.Context(), Principal{Source: src})))
	})
}

func writeAuthError(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]string{
			"code":    code,
			"message": msg,
		},
	})
}
