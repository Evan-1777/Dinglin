package api

import (
	"crypto/rand"
	"fmt"
	"math/big"
	"sync"
	"time"
)

const PairingCodeTTL = 5 * time.Minute

// PairingStore holds ephemeral 6-digit single-use pairing codes in memory.
// ponytail: in-memory TTL map replaces a dedicated SQLite table for short-lived personal pairing codes.
type PairingStore struct {
	mu    sync.Mutex
	codes map[string]time.Time
}

func NewPairingStore() *PairingStore {
	return &PairingStore{codes: make(map[string]time.Time)}
}

// Issue generates a unique 6-digit numeric pairing code valid for PairingCodeTTL.
func (p *PairingStore) Issue(now time.Time) (string, time.Time, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.pruneLocked(now)

	for range 16 {
		n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
		if err != nil {
			return "", time.Time{}, err
		}
		code := fmt.Sprintf("%06d", n.Int64())
		if _, exists := p.codes[code]; !exists {
			exp := now.UTC().Add(PairingCodeTTL)
			p.codes[code] = exp
			return code, exp, nil
		}
	}
	return "", time.Time{}, fmt.Errorf("failed to allocate pairing code")
}

// Consume validates and atomically deletes a pairing code.
func (p *PairingStore) Consume(code string, now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.pruneLocked(now)

	exp, ok := p.codes[code]
	if !ok {
		return false
	}
	delete(p.codes, code)
	return !now.UTC().After(exp)
}

func (p *PairingStore) pruneLocked(now time.Time) {
	u := now.UTC()
	for k, exp := range p.codes {
		if u.After(exp) {
			delete(p.codes, k)
		}
	}
}
