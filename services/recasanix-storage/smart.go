package main

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// smartInfo is what SMART says about a disk. Known is false when the disk does not answer (virtual
// disks, some USB bridges, no smartctl): "no answer" is not "healthy" and is not "failing".
type smartInfo struct {
	Known       bool
	Passed      bool
	Temperature int // degrees Celsius, 0 when unknown
}

type smartEntry struct {
	info smartInfo
	at   time.Time
}

// smartReader asks smartctl, at most once per ttl per disk: the endpoint is polled by the UI, and
// SMART commands are not free (they can wake a spun-down disk, hence `--nocheck=standby` below).
type smartReader struct {
	run   Runner
	ttl   time.Duration
	now   func() time.Time
	mu    sync.Mutex
	cache map[string]smartEntry
}

func newSmartReader(run Runner, ttl time.Duration) *smartReader {
	return &smartReader{run: run, ttl: ttl, now: time.Now, cache: map[string]smartEntry{}}
}

func (s *smartReader) Info(ctx context.Context, devPath string) smartInfo {
	// The path comes from lsblk, not from a request; it is still checked before it becomes an argument.
	if !strings.HasPrefix(devPath, "/dev/") || filepath.Clean(devPath) != devPath || strings.ContainsAny(devPath, " \t\r\n") {
		return smartInfo{}
	}

	s.mu.Lock()
	if e, ok := s.cache[devPath]; ok && s.now().Sub(e.at) < s.ttl {
		s.mu.Unlock()
		return e.info
	}
	s.mu.Unlock()

	// smartctl reports through its exit status too (a bit mask, non-zero for many harmless reasons),
	// so the JSON on stdout is what counts, not the error.
	out, _ := s.run.Run(ctx, "smartctl", "--json=c", "--health", "--attributes", "--nocheck=standby", devPath)
	info := parseSmart(out)

	s.mu.Lock()
	s.cache[devPath] = smartEntry{info: info, at: s.now()}
	s.mu.Unlock()
	return info
}

func parseSmart(data []byte) smartInfo {
	if len(data) == 0 {
		return smartInfo{}
	}
	var doc struct {
		SmartStatus *struct {
			Passed bool `json:"passed"`
		} `json:"smart_status"`
		Temperature *struct {
			Current int `json:"current"`
		} `json:"temperature"`
	}
	if err := json.Unmarshal(data, &doc); err != nil || doc.SmartStatus == nil {
		return smartInfo{}
	}
	info := smartInfo{Known: true, Passed: doc.SmartStatus.Passed}
	if doc.Temperature != nil && doc.Temperature.Current > 0 {
		info.Temperature = doc.Temperature.Current
	}
	return info
}
