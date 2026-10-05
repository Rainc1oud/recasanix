// recasanix-storage is the storage manager behind the web UI's storage widget: a small service that
// lists the machine's disks and volumes, and can turn a blank disk into storage, on the routes the UI
// already calls.
//
// It replaces CasaOS-LocalStorage, which ReCasaOS does not ship (see docs/storage-manager.md).
// Formatting or removing an *existing* storage, and merging storages, are refused with a message that
// says so, until the full storage layer exists.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

type stringList []string

func (s *stringList) String() string     { return fmt.Sprint(*s) }
func (s *stringList) Set(v string) error { *s = append(*s, v); return nil }

func main() {
	var (
		runtimeDir  = flag.String("runtime-dir", "/var/run/casaos", "directory where the stack publishes addresses and credentials")
		listen      = flag.String("listen", "127.0.0.1:0", "address to serve on (loopback only)")
		dataRoot    = flag.String("data-root", "/DATA", "mount point the UI and apps use for the data pool")
		fstab       = flag.String("fstab", "/etc/fstab", "file that declares the persistent mounts")
		poolLabel   = flag.String("pool-label", "recasanix-data", "filesystem label of the data pool")
		poolMount   = flag.String("pool-mount", "/var/lib/recasanix/data", "where the data pool is mounted")
		minDiskSize = flag.Uint64("min-disk-size", 1<<30, "smallest disk, in bytes, offered for creating storage")
		hidden      stringList
	)
	flag.Var(&hidden, "hidden-mount", "mount point of a volume that is system plumbing, not storage (repeatable)")
	flag.Parse()

	cfg := Config{
		DataRoot:       *dataRoot,
		HiddenMounts:   hidden,
		FstabPath:      *fstab,
		PoolLabel:      *poolLabel,
		PoolMountPoint: *poolMount,
		MinDiskSize:    *minDiskSize,
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	if err := run(log, *runtimeDir, *listen, cfg); err != nil {
		log.Error("recasanix-storage failed", "error", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger, runtimeDir, listen string, cfg Config) error {
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		return err
	}
	// Tokens are checked on every request, but there is no reason to be reachable from outside at all.
	if !isLoopbackHostPort(ln.Addr().String()) {
		return fmt.Errorf("refusing to serve on %s: not a loopback address", ln.Addr())
	}

	runner := execRunner{timeout: 10 * time.Second}
	inv := newInventory(cfg, runner, newSmartReader(runner, 5*time.Minute))
	api := &API{inv: inv, creator: newCreator(runner, cfg), log: log}
	auth := newAuthenticator(newJWKSKeys(runtimeDir))

	srv := &http.Server{
		Handler:           auth.Middleware(api.Handler()),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    64 << 10,
	}
	serveErr := make(chan error, 1)
	go func() { serveErr <- srv.Serve(ln) }()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	target := "http://" + ln.Addr().String()
	if err := keepRegistered(ctx, newGatewayClient(runtimeDir), target, routePaths, 30*time.Second, log); err != nil {
		_ = srv.Close()
		return err
	}
	notifyReady()
	log.Info("serving", "address", ln.Addr().String())

	select {
	case <-ctx.Done():
	case err := <-serveErr:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return srv.Shutdown(shutdown)
}
