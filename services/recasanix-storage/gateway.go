package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// The gateway is the only entry point users have; a service is reachable once it registers routes
// there. The fork's gateway lets the local stack do that with a per-boot service token that it
// writes, owner-only, into the runtime directory. Such registrations are deliberately not persisted
// and do not expire: their owner registers again whenever it starts — and, here, whenever the
// gateway has forgotten them (it restarted).
const (
	managementURLFile = "management.url"
	serviceTokenFile  = "gateway.token"
	routesAPI         = "/v1/gateway/routes"
	maxSmallFile      = 1 << 10
	maxAPIResponse    = 64 << 10
)

type gatewayClient struct {
	runtimeDir string
	client     *http.Client
}

func newGatewayClient(runtimeDir string) *gatewayClient {
	return &gatewayClient{
		runtimeDir: runtimeDir,
		client: &http.Client{
			Timeout: 10 * time.Second,
			// A redirect must never carry the service credential somewhere else.
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}
}

// readSmallFile reads a credential or address file, bounded.
func (g *gatewayClient) readSmallFile(name string) (string, error) {
	f, err := os.Open(filepath.Join(g.runtimeDir, name))
	if err != nil {
		return "", err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxSmallFile+1))
	if err != nil {
		return "", err
	}
	if len(data) > maxSmallFile {
		return "", fmt.Errorf("%s is too large", name)
	}
	return strings.TrimSpace(string(data)), nil
}

// do sends one authenticated management request. Address and token are read on every call, so a
// gateway restart (new port, new token) is picked up without restarting this service.
func (g *gatewayClient) do(ctx context.Context, method, path string, body []byte) (*http.Response, error) {
	base, err := loopbackURL(filepath.Join(g.runtimeDir, managementURLFile))
	if err != nil {
		return nil, fmt.Errorf("gateway management address: %w", err)
	}
	token, err := g.readSmallFile(serviceTokenFile)
	if err != nil || token == "" {
		return nil, errors.New("gateway service token is not available")
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimSuffix(base, "/")+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if len(body) > 0 {
		req.Header.Set("Content-Type", "application/json")
	}
	return g.client.Do(req)
}

type gatewayRoute struct {
	Path   string `json:"path"`
	Target string `json:"target"`
}

func (g *gatewayClient) routes(ctx context.Context) (map[string]string, error) {
	resp, err := g.do(ctx, http.MethodGet, routesAPI, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, maxAPIResponse))
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("list routes: status %d", resp.StatusCode)
	}
	var list []gatewayRoute
	if err := json.Unmarshal(body, &list); err != nil {
		return nil, fmt.Errorf("list routes: %w", err)
	}
	out := make(map[string]string, len(list))
	for _, r := range list {
		out[r.Path] = r.Target
	}
	return out, nil
}

func (g *gatewayClient) create(ctx context.Context, route gatewayRoute) error {
	body, err := json.Marshal(route)
	if err != nil {
		return err
	}
	resp, err := g.do(ctx, http.MethodPost, routesAPI, body)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, maxAPIResponse))
	if resp.StatusCode != http.StatusCreated {
		return fmt.Errorf("create route %s: status %d", route.Path, resp.StatusCode)
	}
	return nil
}

// ensure registers every path that is missing, or points somewhere else, and reports how many it had
// to create. Existing correct routes are left alone: registering is not free (the gateway rewrites its
// route table), so a healthy gateway sees a read and nothing more.
func (g *gatewayClient) ensure(ctx context.Context, target string, paths []string) (created int, err error) {
	have, err := g.routes(ctx)
	if err != nil {
		return 0, err
	}
	for _, p := range paths {
		if have[p] == target {
			continue
		}
		if err := g.create(ctx, gatewayRoute{Path: p, Target: target}); err != nil {
			return created, err
		}
		created++
	}
	return created, nil
}

// keepRegistered registers the routes, retrying until the gateway is up, then checks on them
// periodically. It returns once the first registration succeeded (so the caller can report ready) and
// keeps watching in the background until ctx ends.
func keepRegistered(ctx context.Context, g *gatewayClient, target string, paths []string, every time.Duration, log *slog.Logger) error {
	deadline := time.Now().Add(2 * time.Minute)
	for {
		n, err := g.ensure(ctx, target, paths)
		if err == nil {
			log.Info("routes registered with the gateway", "created", n, "paths", paths)
			break
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("register routes: %w", err)
		}
		log.Warn("gateway not ready, retrying", "error", err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}

	go func() {
		t := time.NewTicker(every)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if n, err := g.ensure(ctx, target, paths); err != nil {
					log.Warn("could not check the gateway routes", "error", err)
				} else if n > 0 {
					log.Warn("the gateway had lost routes; registered them again", "created", n)
				}
			}
		}
	}()
	return nil
}

func isLoopbackHostPort(hostport string) bool {
	host, port, err := net.SplitHostPort(hostport)
	if err != nil || port == "" {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
