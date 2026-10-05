package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	jwt "github.com/golang-jwt/jwt/v4"
)

// Authentication follows the rules of the ReCasaOS root service (route/v1.go), so a user's token
// works here exactly where it works there, and nothing else does:
//
//   - `Authorization: Bearer <token>` only. A token in the query string leaks into logs, history and
//     referers, and is never accepted.
//   - an ES256 JWT, verified against the key the user service publishes (JWKS). Other algorithms,
//     including "none" and HMAC with the public key as the secret, are refused before any key is used.
//   - it must expire, and the issuer must be the access-token issuer: a refresh token is not an access
//     token.
//   - there is no loopback exemption. This service listens on loopback only, but any local process can
//     reach that, and so "it came from localhost" is not an identity.
const (
	accessTokenIssuer = "casaos"
	jwksPath          = ".well-known/jwks.json"
	userServiceURL    = "user-service.url"
	jwksTTL           = 10 * time.Second
	maxJWKSBytes      = 64 << 10
)

var errUnauthorized = errors.New("unauthorized")

// keySource yields the public key tokens must verify against.
type keySource interface {
	PublicKey() (*ecdsa.PublicKey, error)
}

// Authenticator validates the bearer token of a request.
type Authenticator struct {
	keys keySource
}

func newAuthenticator(keys keySource) *Authenticator { return &Authenticator{keys: keys} }

type accessClaims struct {
	jwt.RegisteredClaims
	Username string `json:"username"`
	ID       int    `json:"id"`
}

// Authenticate reports whether the request carries a valid access token. Every failure is the same
// error: the caller must not be able to tell a bad signature from an expired token.
func (a *Authenticator) Authenticate(r *http.Request) error {
	const prefix = "Bearer "
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, prefix) {
		return errUnauthorized
	}
	raw := strings.TrimSpace(strings.TrimPrefix(header, prefix))
	if raw == "" {
		return errUnauthorized
	}

	// WithValidMethods is belt and braces: with an ECDSA key the library already refuses HMAC, RSA and
	// "none" by key type. It is kept so the policy is written down where it is enforced, and so that
	// no future key source can quietly widen it.
	claims := &accessClaims{}
	token, err := jwt.ParseWithClaims(raw, claims, func(*jwt.Token) (any, error) {
		return a.keys.PublicKey()
	}, jwt.WithValidMethods([]string{"ES256"}))
	if err != nil || !token.Valid {
		return errUnauthorized
	}
	// jwt validates exp only when present; a token that never expires is not one we issued.
	if claims.ExpiresAt == nil || claims.Issuer != accessTokenIssuer {
		return errUnauthorized
	}
	return nil
}

// Middleware refuses every request that does not authenticate.
func (a *Authenticator) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := a.Authenticate(r); err != nil {
			writeJSON(w, http.StatusUnauthorized, envelope{Success: http.StatusUnauthorized, Message: "Unauthorized"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

// --- the key: fetched from the user service, as the other services do -----------------------------

// jwksKeys reads the user service's address from the runtime directory and fetches its JWKS. The key
// is cached briefly; a failure to obtain it fails closed.
type jwksKeys struct {
	runtimeDir string
	client     *http.Client
	now        func() time.Time

	mu      sync.Mutex
	key     *ecdsa.PublicKey
	fetched time.Time
}

func newJWKSKeys(runtimeDir string) *jwksKeys {
	return &jwksKeys{
		runtimeDir: runtimeDir,
		now:        time.Now,
		client: &http.Client{
			Timeout: 5 * time.Second,
			// never follow a redirect away from the user service
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}
}

func (j *jwksKeys) PublicKey() (*ecdsa.PublicKey, error) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.key != nil && j.now().Sub(j.fetched) < jwksTTL {
		return j.key, nil
	}

	base, err := loopbackURL(filepath.Join(j.runtimeDir, userServiceURL))
	if err != nil {
		return nil, fmt.Errorf("user service address: %w", err)
	}
	resp, err := j.client.Get(strings.TrimSuffix(base, "/") + "/" + jwksPath)
	if err != nil {
		return nil, fmt.Errorf("fetch JWKS: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fetch JWKS: status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxJWKSBytes))
	if err != nil {
		return nil, fmt.Errorf("read JWKS: %w", err)
	}
	key, err := parseJWKS(body)
	if err != nil {
		return nil, err
	}
	j.key, j.fetched = key, j.now()
	return key, nil
}

func parseJWKS(data []byte) (*ecdsa.PublicKey, error) {
	var set struct {
		Keys []struct {
			Kty string `json:"kty"`
			Crv string `json:"crv"`
			X   string `json:"x"`
			Y   string `json:"y"`
		} `json:"keys"`
	}
	if err := json.Unmarshal(data, &set); err != nil {
		return nil, fmt.Errorf("parse JWKS: %w", err)
	}
	if len(set.Keys) == 0 {
		return nil, errors.New("JWKS has no keys")
	}
	k := set.Keys[0] // the user service signs with its first key
	if k.Kty != "EC" || k.Crv != "P-256" {
		return nil, fmt.Errorf("JWKS key is %s/%s, want EC/P-256", k.Kty, k.Crv)
	}
	x, err := base64.RawURLEncoding.DecodeString(k.X)
	if err != nil {
		return nil, fmt.Errorf("JWKS x: %w", err)
	}
	y, err := base64.RawURLEncoding.DecodeString(k.Y)
	if err != nil {
		return nil, fmt.Errorf("JWKS y: %w", err)
	}
	key := &ecdsa.PublicKey{Curve: elliptic.P256(), X: new(big.Int).SetBytes(x), Y: new(big.Int).SetBytes(y)}
	// refuse a point that is not on the curve (invalid-curve attacks)
	if _, err := key.ECDH(); err != nil {
		return nil, fmt.Errorf("JWKS key is not a valid P-256 point: %w", err)
	}
	return key, nil
}

// loopbackURL reads a service address file from the runtime directory and accepts it only if it is a
// plain http URL to an explicit loopback IP and port.
func loopbackURL(file string) (string, error) {
	raw, err := os.ReadFile(file)
	if err != nil {
		return "", err
	}
	value := strings.TrimSpace(string(raw))
	u, err := url.Parse(value)
	if err != nil || u.Scheme != "http" || u.User != nil || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("not a plain http URL")
	}
	if !isLoopbackHostPort(u.Host) {
		return "", errors.New("not a loopback address with an explicit port")
	}
	return value, nil
}
