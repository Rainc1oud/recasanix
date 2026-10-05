package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeRunner answers commands from a table and records every call, so tests can assert both what the
// service asked for and how (argument vector, no shell).
type fakeRunner struct {
	mu      sync.Mutex
	outputs map[string][]byte
	errs    map[string]error
	calls   []string
}

func newFakeRunner() *fakeRunner {
	return &fakeRunner{outputs: map[string][]byte{}, errs: map[string]error{}}
}

func key(name string, args ...string) string { return name + " " + strings.Join(args, " ") }

func (f *fakeRunner) Run(_ context.Context, name string, args ...string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	k := key(name, args...)
	f.calls = append(f.calls, k)
	return f.outputs[k], f.errs[k]
}

func (f *fakeRunner) count(prefix string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.calls {
		if strings.HasPrefix(c, prefix) {
			n++
		}
	}
	return n
}

var lsblkCall = key("lsblk", "--json", "--bytes", "--output", lsblkColumns)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// testInventory builds an inventory over a fixture; smartctl answers nothing, like a virtual disk.
func testInventory(t *testing.T, lsblkFixture string, cfg Config) (*Inventory, *fakeRunner) {
	t.Helper()
	run := newFakeRunner()
	run.outputs[lsblkCall] = fixture(t, lsblkFixture)
	return newInventory(cfg, run, newSmartReader(run, time.Minute)), run
}

func discardLog() *slog.Logger { return slog.New(slog.NewTextHandler(nopWriter{}, nil)) }

type nopWriter struct{}

func (nopWriter) Write(p []byte) (int, error) { return len(p), nil }

// baseConfig is the appliance's real layout, its actual defaults included: tests that don't care about
// the pool or the size threshold still exercise them as configured in production.
func baseConfig(fstab string) Config {
	return Config{
		DataRoot:       "/DATA",
		HiddenMounts:   []string{"/var/lib/recasanix/state"},
		FstabPath:      fstab,
		PoolLabel:      "recasanix-data",
		PoolMountPoint: "/var/lib/recasanix/data",
		MinDiskSize:    1 << 30,
	}
}

// testServerWithCreator is testServer (in api_test.go) plus the write path: it returns the fakeRunner
// too, so a test can assert both the HTTP response and, via run.calls, exactly what commands ran.
func testServerWithCreator(t *testing.T, fixtureName string) (h http.Handler, run *fakeRunner, bearer string) {
	t.Helper()
	cfg := baseConfig("")
	run = newFakeRunner()
	run.outputs[lsblkCall] = fixture(t, fixtureName)
	inv := newInventory(cfg, run, newSmartReader(run, time.Minute))
	priv := newKey(t)
	api := &API{inv: inv, creator: newCreator(run, cfg), log: discardLog()}
	h = newAuthenticator(staticKey{key: &priv.PublicKey}).Middleware(api.Handler())
	bearer = "Bearer " + token(t, priv, tokenOpts{issuer: "casaos", expires: in(time.Hour)})
	return
}
