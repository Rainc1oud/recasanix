package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	jwt "github.com/golang-jwt/jwt/v4"
)

type staticKey struct {
	key *ecdsa.PublicKey
	err error
}

func (s staticKey) PublicKey() (*ecdsa.PublicKey, error) { return s.key, s.err }

func newKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

type tokenOpts struct {
	issuer  string
	expires *time.Time // nil: no exp claim
	method  jwt.SigningMethod
	key     any
}

// token signs a token the way the user service does, unless told otherwise.
func token(t *testing.T, priv *ecdsa.PrivateKey, o tokenOpts) string {
	t.Helper()
	if o.method == nil {
		o.method = jwt.SigningMethodES256
	}
	if o.key == nil {
		o.key = priv
	}
	claims := accessClaims{
		RegisteredClaims: jwt.RegisteredClaims{Issuer: o.issuer, IssuedAt: jwt.NewNumericDate(time.Now())},
		Username:         "admin", ID: 1,
	}
	if o.expires != nil {
		claims.ExpiresAt = jwt.NewNumericDate(*o.expires)
	}
	s, err := jwt.NewWithClaims(o.method, claims).SignedString(o.key)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func in(d time.Duration) *time.Time { x := time.Now().Add(d); return &x }

func request(bearer string) *http.Request {
	r := httptest.NewRequest(http.MethodGet, "/v1/disks", nil)
	if bearer != "" {
		r.Header.Set("Authorization", bearer)
	}
	return r
}

func TestAuthenticate(t *testing.T) {
	priv, other := newKey(t), newKey(t)
	auth := newAuthenticator(staticKey{key: &priv.PublicKey})

	good := token(t, priv, tokenOpts{issuer: "casaos", expires: in(time.Hour)})
	if err := auth.Authenticate(request("Bearer " + good)); err != nil {
		t.Fatalf("a valid access token was refused: %v", err)
	}

	bad := map[string]string{
		"no header":                      "",
		"not a bearer credential":        "Basic " + good,
		"lower-case scheme":              "bearer " + good,
		"empty token":                    "Bearer ",
		"garbage":                        "Bearer not.a.token",
		"expired":                        "Bearer " + token(t, priv, tokenOpts{issuer: "casaos", expires: in(-time.Minute)}),
		"a refresh token":                "Bearer " + token(t, priv, tokenOpts{issuer: "refresh", expires: in(time.Hour)}),
		"no issuer":                      "Bearer " + token(t, priv, tokenOpts{issuer: "", expires: in(time.Hour)}),
		"never expires":                  "Bearer " + token(t, priv, tokenOpts{issuer: "casaos", expires: nil}),
		"signed by another key":          "Bearer " + token(t, other, tokenOpts{issuer: "casaos", expires: in(time.Hour)}),
		"alg none":                       "Bearer " + token(t, priv, tokenOpts{issuer: "casaos", expires: in(time.Hour), method: jwt.SigningMethodNone, key: jwt.UnsafeAllowNoneSignatureType}),
		"HMAC keyed with the public key": "Bearer " + hmacWithPublicKey(t, priv),
	}
	for name, header := range bad {
		if err := auth.Authenticate(request(header)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}

	// a token in the query string is never read
	r := httptest.NewRequest(http.MethodGet, "/v1/disks?token="+good+"&access_token="+good, nil)
	if err := auth.Authenticate(r); err == nil {
		t.Error("a token in the query string was accepted")
	}

	// tampering with the payload breaks the signature
	tampered := good[:len(good)-4] + "AAAA"
	if err := auth.Authenticate(request("Bearer " + tampered)); err == nil {
		t.Error("a tampered token was accepted")
	}
}

// The classic algorithm-confusion attack: sign with HMAC, using the public key as the secret.
func hmacWithPublicKey(t *testing.T, priv *ecdsa.PrivateKey) string {
	t.Helper()
	der, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return token(t, priv, tokenOpts{issuer: "casaos", expires: in(time.Hour), method: jwt.SigningMethodHS256, key: der})
}

func TestAuthenticationFailsClosedWithoutAKey(t *testing.T) {
	priv := newKey(t)
	auth := newAuthenticator(staticKey{err: fmt.Errorf("user service is down")})
	good := token(t, priv, tokenOpts{issuer: "casaos", expires: in(time.Hour)})
	if err := auth.Authenticate(request("Bearer " + good)); err == nil {
		t.Fatal("a token was accepted although no key could be obtained")
	}
}

func TestMiddlewareAnswers401WithoutLeakingWhy(t *testing.T) {
	priv := newKey(t)
	called := false
	h := newAuthenticator(staticKey{key: &priv.PublicKey}).Middleware(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { called = true }))

	bodies := map[string]bool{}
	for _, header := range []string{"", "Bearer x", "Bearer " + token(t, priv, tokenOpts{issuer: "refresh", expires: in(time.Hour)})} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, request(header))
		if w.Code != http.StatusUnauthorized {
			t.Fatalf("status %d for %q", w.Code, header)
		}
		bodies[w.Body.String()] = true
	}
	if called {
		t.Fatal("the handler ran for an unauthenticated request")
	}
	if len(bodies) != 1 {
		t.Fatalf("different failures are distinguishable: %v", bodies)
	}
}

// --- JWKS -------------------------------------------------------------------------------------------

func jwksJSON(pub *ecdsa.PublicKey) string {
	return fmt.Sprintf(`{"keys":[{"kty":"EC","crv":"P-256","x":%q,"y":%q}]}`,
		base64.RawURLEncoding.EncodeToString(pub.X.Bytes()), base64.RawURLEncoding.EncodeToString(pub.Y.Bytes()))
}

// userService serves a JWKS and writes user-service.url into a fresh runtime directory.
func userService(t *testing.T, handler http.HandlerFunc) (dir string, srv *httptest.Server) {
	t.Helper()
	srv = httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	dir = t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "user-service.url"), []byte(srv.URL+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir, srv
}

func TestJWKSKeyIsFetchedFromTheUserServiceAndCached(t *testing.T) {
	priv := newKey(t)
	var hits atomic.Int32
	dir, _ := userService(t, func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		if r.URL.Path != "/.well-known/jwks.json" {
			http.NotFound(w, r)
			return
		}
		fmt.Fprint(w, jwksJSON(&priv.PublicKey))
	})
	keys := newJWKSKeys(dir)
	now := time.Now()
	keys.now = func() time.Time { return now }

	k, err := keys.PublicKey()
	if err != nil || k.X.Cmp(priv.PublicKey.X) != 0 {
		t.Fatalf("key = %v, err = %v", k, err)
	}
	if _, err := keys.PublicKey(); err != nil || hits.Load() != 1 {
		t.Fatalf("expected the cached key, hits = %d (%v)", hits.Load(), err)
	}
	now = now.Add(11 * time.Second)
	if _, err := keys.PublicKey(); err != nil || hits.Load() != 2 {
		t.Fatalf("expected a refresh after the ttl, hits = %d (%v)", hits.Load(), err)
	}

	// and it really authenticates a token end to end
	auth := newAuthenticator(keys)
	if err := auth.Authenticate(request("Bearer " + token(t, priv, tokenOpts{issuer: "casaos", expires: in(time.Hour)}))); err != nil {
		t.Fatal(err)
	}
}

func TestJWKSRefusesWhatItCannotTrust(t *testing.T) {
	priv := newKey(t)
	ok := jwksJSON(&priv.PublicKey)
	cases := map[string]string{
		"no keys":           `{"keys":[]}`,
		"an RSA key":        `{"keys":[{"kty":"RSA","crv":"","x":"AA","y":"AA"}]}`,
		"another curve":     `{"keys":[{"kty":"EC","crv":"P-384","x":"AA","y":"AA"}]}`,
		"a point off curve": `{"keys":[{"kty":"EC","crv":"P-256","x":"AQ","y":"AQ"}]}`,
		"not JSON":          `<html>`,
	}
	for name, body := range cases {
		dir, _ := userService(t, func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, body) })
		if _, err := newJWKSKeys(dir).PublicKey(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	// the control: the same machinery accepts a good key
	dir, _ := userService(t, func(w http.ResponseWriter, _ *http.Request) { fmt.Fprint(w, ok) })
	if _, err := newJWKSKeys(dir).PublicKey(); err != nil {
		t.Fatal(err)
	}

	// a failing user service is an error, not a stale key
	dir, _ = userService(t, func(w http.ResponseWriter, _ *http.Request) { http.Error(w, "boom", 500) })
	if _, err := newJWKSKeys(dir).PublicKey(); err == nil {
		t.Error("an HTTP error was treated as a key")
	}
}

func TestUserServiceAddressMustBeLoopback(t *testing.T) {
	for _, addr := range []string{"http://192.0.2.1:8080", "http://example.com:80", "https://127.0.0.1:8080", "http://127.0.0.1", "http://user:pw@127.0.0.1:8080", "http://127.0.0.1:8080/x", "http://127.0.0.1:8080?x=1", "not a url"} {
		dir := t.TempDir()
		os.WriteFile(filepath.Join(dir, "user-service.url"), []byte(addr), 0o600)
		if _, err := newJWKSKeys(dir).PublicKey(); err == nil {
			t.Errorf("%q accepted", addr)
		}
	}
	if _, err := newJWKSKeys(t.TempDir()).PublicKey(); err == nil {
		t.Error("a missing address file was accepted")
	}
}

var _ = json.Marshal
