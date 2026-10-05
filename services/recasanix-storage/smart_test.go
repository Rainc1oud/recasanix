package main

import (
	"context"
	"testing"
	"time"
)

var smartCall = func(path string) string {
	return key("smartctl", "--json=c", "--health", "--attributes", "--nocheck=standby", path)
}

func TestParseSmart(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want smartInfo
	}{
		{"passed with temperature", `{"smart_status":{"passed":true},"temperature":{"current":37}}`, smartInfo{Known: true, Passed: true, Temperature: 37}},
		{"failed", `{"smart_status":{"passed":false},"temperature":{"current":41}}`, smartInfo{Known: true, Passed: false, Temperature: 41}},
		{"no temperature", `{"smart_status":{"passed":true}}`, smartInfo{Known: true, Passed: true}},
		{"no SMART support: an error report without a status", `{"smartctl":{"exit_status":4}}`, smartInfo{}},
		{"not JSON", `garbage`, smartInfo{}},
		{"empty", ``, smartInfo{}},
	}
	for _, c := range cases {
		if got := parseSmart([]byte(c.in)); got != c.want {
			t.Errorf("%s: got %+v, want %+v", c.name, got, c.want)
		}
	}
}

func TestHealthRendering(t *testing.T) {
	if health(smartInfo{Known: true, Passed: true}) != "true" {
		t.Error("passed must be non-empty")
	}
	if health(smartInfo{}) != "true" {
		t.Error("unknown must not look failing")
	}
	if health(smartInfo{Known: true, Passed: false}) != "" {
		t.Error("a failing disk must be the empty string: the UI shows that as Damage")
	}
}

func TestSmartIsCachedAndRefreshed(t *testing.T) {
	run := newFakeRunner()
	run.outputs[smartCall("/dev/sda")] = []byte(`{"smart_status":{"passed":true},"temperature":{"current":30}}`)
	s := newSmartReader(run, time.Minute)
	now := time.Now()
	s.now = func() time.Time { return now }

	s.Info(context.Background(), "/dev/sda")
	s.Info(context.Background(), "/dev/sda")
	if n := run.count("smartctl"); n != 1 {
		t.Fatalf("smartctl asked %d times within the ttl", n)
	}
	now = now.Add(2 * time.Minute)
	s.Info(context.Background(), "/dev/sda")
	if n := run.count("smartctl"); n != 2 {
		t.Fatalf("smartctl asked %d times after the ttl", n)
	}
}

func TestSmartNeverGetsAnUnvettedPath(t *testing.T) {
	run := newFakeRunner()
	s := newSmartReader(run, time.Minute)
	for _, bad := range []string{"", "sda", "/etc/passwd", "/dev/sda; reboot", "/dev/../etc/passwd", "/dev/sd a", "/dev/sda\n"} {
		if info := s.Info(context.Background(), bad); info.Known {
			t.Errorf("%q answered", bad)
		}
	}
	if len(run.calls) != 0 {
		t.Fatalf("smartctl was started for a bad path: %v", run.calls)
	}
}

func TestSmartUsesTheOutputEvenWhenTheExitStatusIsNonZero(t *testing.T) {
	run := newFakeRunner()
	run.outputs[smartCall("/dev/sdb")] = []byte(`{"smart_status":{"passed":false}}`)
	run.errs[smartCall("/dev/sdb")] = context.DeadlineExceeded // stands for "exit status 8"
	s := newSmartReader(run, time.Minute)
	if info := s.Info(context.Background(), "/dev/sdb"); !info.Known || info.Passed {
		t.Fatalf("a failing disk must be reported as failing whatever the exit status: %+v", info)
	}
}
