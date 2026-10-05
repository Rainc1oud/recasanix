package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// fakeGateway implements the part of the gateway's management API this service uses: it demands the
// service token, and keeps the routes in memory like a gateway that does not persist service routes.
type fakeGateway struct {
	mu     sync.Mutex
	token  string
	routes map[string]string
	posts  int
	srv    *httptest.Server
}

func newFakeGateway(t *testing.T, token string) (*fakeGateway, string) {
	t.Helper()
	g := &fakeGateway{token: token, routes: map[string]string{}}
	g.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+g.token {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		g.mu.Lock()
		defer g.mu.Unlock()
		switch {
		case r.Method == "GET" && r.URL.Path == "/v1/gateway/routes":
			list := []gatewayRoute{}
			for p, tgt := range g.routes {
				list = append(list, gatewayRoute{Path: p, Target: tgt})
			}
			json.NewEncoder(w).Encode(list)
		case r.Method == "POST" && r.URL.Path == "/v1/gateway/routes":
			var rt gatewayRoute
			if json.NewDecoder(r.Body).Decode(&rt) != nil || rt.Path == "" {
				http.Error(w, "bad", http.StatusBadRequest)
				return
			}
			g.posts++
			g.routes[rt.Path] = rt.Target
			w.WriteHeader(http.StatusCreated)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(g.srv.Close)

	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "management.url"), []byte(g.srv.URL), 0o600)
	os.WriteFile(filepath.Join(dir, "gateway.token"), []byte(token+"\n"), 0o600)
	return g, dir
}

func TestRoutesAreRegisteredWithTheServiceToken(t *testing.T) {
	gw, dir := newFakeGateway(t, "s3cret")
	c := newGatewayClient(dir)

	n, err := c.ensure(context.Background(), "http://127.0.0.1:9", routePaths)
	if err != nil || n != len(routePaths) {
		t.Fatalf("created %d, err %v", n, err)
	}
	for _, p := range []string{"/v1/disks", "/v1/storage", "/v2/local_storage"} {
		if gw.routes[p] != "http://127.0.0.1:9" {
			t.Errorf("route %s -> %q", p, gw.routes[p])
		}
	}
}

func TestHealthyRoutesAreLeftAlone(t *testing.T) {
	gw, dir := newFakeGateway(t, "s3cret")
	c := newGatewayClient(dir)
	c.ensure(context.Background(), "http://127.0.0.1:9", routePaths)
	before := gw.posts
	if n, err := c.ensure(context.Background(), "http://127.0.0.1:9", routePaths); err != nil || n != 0 || gw.posts != before {
		t.Fatalf("a second check re-registered: n=%d err=%v posts %d->%d", n, err, before, gw.posts)
	}
}

func TestLostRoutesAreRegisteredAgain(t *testing.T) {
	gw, dir := newFakeGateway(t, "s3cret")
	c := newGatewayClient(dir)
	c.ensure(context.Background(), "http://127.0.0.1:9", routePaths)

	gw.mu.Lock()
	gw.routes = map[string]string{} // the gateway restarted and forgot everything
	gw.mu.Unlock()
	if n, err := c.ensure(context.Background(), "http://127.0.0.1:9", routePaths); err != nil || n != len(routePaths) {
		t.Fatalf("n=%d err=%v", n, err)
	}

	// a route that points somewhere else (a previous instance, another port) is corrected
	gw.mu.Lock()
	gw.routes["/v1/disks"] = "http://127.0.0.1:1"
	gw.mu.Unlock()
	if n, err := c.ensure(context.Background(), "http://127.0.0.1:9", routePaths); err != nil || n != 1 || gw.routes["/v1/disks"] != "http://127.0.0.1:9" {
		t.Fatalf("n=%d err=%v route=%q", n, err, gw.routes["/v1/disks"])
	}
}

func TestTheTokenIsReadAgainAfterAGatewayRestart(t *testing.T) {
	gw, dir := newFakeGateway(t, "old-token")
	c := newGatewayClient(dir)
	if _, err := c.ensure(context.Background(), "http://127.0.0.1:9", routePaths); err != nil {
		t.Fatal(err)
	}
	gw.mu.Lock()
	gw.token, gw.routes = "new-token", map[string]string{}
	gw.mu.Unlock()
	os.WriteFile(filepath.Join(dir, "gateway.token"), []byte("new-token\n"), 0o600)
	if _, err := c.ensure(context.Background(), "http://127.0.0.1:9", routePaths); err != nil {
		t.Fatalf("the new token was not picked up: %v", err)
	}
}

func TestWrongOrMissingCredentialsFail(t *testing.T) {
	_, dir := newFakeGateway(t, "s3cret")
	os.WriteFile(filepath.Join(dir, "gateway.token"), []byte("wrong\n"), 0o600)
	if _, err := newGatewayClient(dir).ensure(context.Background(), "http://127.0.0.1:9", routePaths); err == nil {
		t.Error("a wrong token was accepted by the fake, or ignored by the client")
	}
	os.Remove(filepath.Join(dir, "gateway.token"))
	if _, err := newGatewayClient(dir).ensure(context.Background(), "http://127.0.0.1:9", routePaths); err == nil {
		t.Error("registration without a token succeeded")
	}
	if _, err := newGatewayClient(t.TempDir()).ensure(context.Background(), "http://127.0.0.1:9", routePaths); err == nil {
		t.Error("registration without a gateway succeeded")
	}
}

func TestTheServiceTokenIsNeverSentBeyondLoopback(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "gateway.token"), []byte("s3cret\n"), 0o600)
	for _, addr := range []string{"http://192.0.2.7:8080", "http://gateway.example:8080", "https://127.0.0.1:8080", "http://127.0.0.1"} {
		os.WriteFile(filepath.Join(dir, "management.url"), []byte(addr), 0o600)
		if _, err := newGatewayClient(dir).routes(context.Background()); err == nil {
			t.Errorf("%q was used as the management address", addr)
		}
	}
}

func TestAnOversizedCredentialFileIsRefused(t *testing.T) {
	_, dir := newFakeGateway(t, "s3cret")
	big := make([]byte, 4096)
	for i := range big {
		big[i] = 'a'
	}
	os.WriteFile(filepath.Join(dir, "gateway.token"), big, 0o600)
	if _, err := newGatewayClient(dir).routes(context.Background()); err == nil {
		t.Error("an oversized token file was read")
	}
}

func TestRedirectsAreNotFollowedWithTheCredential(t *testing.T) {
	var leaked bool
	evil := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" {
			leaked = true
		}
	}))
	defer evil.Close()
	redirector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, evil.URL, http.StatusTemporaryRedirect)
	}))
	defer redirector.Close()
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "management.url"), []byte(redirector.URL), 0o600)
	os.WriteFile(filepath.Join(dir, "gateway.token"), []byte("s3cret"), 0o600)
	newGatewayClient(dir).routes(context.Background())
	if leaked {
		t.Fatal("the service token followed a redirect")
	}
}

func TestKeepRegisteredWaitsForTheGatewayThenWatchesIt(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// the gateway comes up a moment after the service
	go func() {
		time.Sleep(300 * time.Millisecond)
		gw, gdir := newFakeGateway(t, "s3cret")
		_ = gw
		for _, f := range []string{"management.url", "gateway.token"} {
			b, _ := os.ReadFile(filepath.Join(gdir, f))
			os.WriteFile(filepath.Join(dir, f), b, 0o600)
		}
	}()
	if err := keepRegistered(ctx, newGatewayClient(dir), "http://127.0.0.1:9", routePaths, 50*time.Millisecond, discardLog()); err != nil {
		t.Fatal(err)
	}
}

func TestLoopbackChecks(t *testing.T) {
	yes := []string{"127.0.0.1:80", "[::1]:80", "127.9.9.9:1"}
	no := []string{"0.0.0.0:80", "192.168.1.5:80", "localhost:80", "127.0.0.1", ":80", "[::]:80"}
	for _, a := range yes {
		if !isLoopbackHostPort(a) {
			t.Errorf("%s should be loopback", a)
		}
	}
	for _, a := range no {
		if isLoopbackHostPort(a) {
			t.Errorf("%s should not be loopback", a)
		}
	}
}
