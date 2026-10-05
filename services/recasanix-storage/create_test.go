package main

import (
	"context"
	"os"
	"testing"
)

func newTestCreator(run *fakeRunner) *Creator {
	return newCreator(run, baseConfig(""))
}

func TestCreateFormatsABlankDiskWhenNoPoolExists(t *testing.T) {
	run := newFakeRunner()
	run.outputs[lsblkCall] = fixture(t, "vm-blank-disk.json") // no "recasanix-data" label anywhere
	if err := newTestCreator(run).Create(context.Background(), "/dev/vdb"); err != nil {
		t.Fatal(err)
	}
	want := []string{
		lsblkCall,
		key("mkfs.btrfs", "-f", "-L", "recasanix-data", "--", "/dev/vdb"),
		key("udevadm", "settle", "--timeout=10"),
		key("mkdir", "-p", "--", "/var/lib/recasanix/data/DATA"),
		key("mountpoint", "-q", "--", "/var/lib/recasanix/data"),
		key("systemctl", "start", "--", "DATA.mount", "docker.service"),
		key("systemctl", "restart", "--", "casaos.service", "casaos-app-management.service"),
	}
	if len(run.calls) != len(want) {
		t.Fatalf("calls = %v, want %v", run.calls, want)
	}
	for i, w := range want {
		if run.calls[i] != w {
			t.Errorf("call %d = %q, want %q", i, run.calls[i], w)
		}
	}
}

func TestCreateExtendsAnExistingPool(t *testing.T) {
	run := newFakeRunner()
	run.outputs[lsblkCall] = fixture(t, "image-with-pool.json") // "sda" already carries the pool's label
	if err := newTestCreator(run).Create(context.Background(), "/dev/sdc"); err != nil {
		t.Fatal(err)
	}
	if run.calls[1] != key("btrfs", "device", "add", "-f", "--", "/dev/sdc", "/var/lib/recasanix/data") {
		t.Fatalf("did not extend the existing pool: %v", run.calls)
	}
	for _, c := range run.calls {
		if c == key("mkfs.btrfs", "-f", "-L", "recasanix-data", "--", "/dev/sdc") {
			t.Fatal("a disk was formatted although a pool already exists — this would have destroyed it")
		}
	}
}

func TestCreateStopsAtTheFirstFailingStep(t *testing.T) {
	steps := []string{
		key("mkfs.btrfs", "-f", "-L", "recasanix-data", "--", "/dev/vdb"),
		key("udevadm", "settle", "--timeout=10"),
		key("mkdir", "-p", "--", "/var/lib/recasanix/data/DATA"),
		key("mountpoint", "-q", "--", "/var/lib/recasanix/data"),
		key("systemctl", "start", "--", "DATA.mount", "docker.service"),
		key("systemctl", "restart", "--", "casaos.service", "casaos-app-management.service"),
	}
	for i, failing := range steps {
		run := newFakeRunner()
		run.outputs[lsblkCall] = fixture(t, "vm-blank-disk.json")
		run.errs[failing] = os.ErrPermission

		err := newTestCreator(run).Create(context.Background(), "/dev/vdb")
		if err == nil {
			t.Fatalf("step %d (%s): expected an error", i, failing)
		}
		// exactly the steps up to and including the failing one ran; nothing after it did
		got := run.calls[1:] // [0] is the lsblk listing
		if len(got) != i+1 {
			t.Fatalf("step %d (%s): ran %v, expected to stop after the failing step", i, failing, got)
		}
	}
}

func TestPoolExists(t *testing.T) {
	yes, _ := parseLsblk(fixture(t, "image-with-pool.json"))
	if !poolExists(yes, "recasanix-data") {
		t.Error("a disk labelled recasanix-data was not found")
	}
	no, _ := parseLsblk(fixture(t, "vm-blank-disk.json"))
	if poolExists(no, "recasanix-data") {
		t.Error("found a pool that is not there")
	}
}
