package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

// lsblk JSON for tests: system disk vda, then the given disks.
func machine(disks ...string) []byte {
	all := append([]string{`{"name":"vda","path":"/dev/vda","type":"disk","size":8589934592,"mountpoints":[null],
	  "children":[{"name":"vda1","path":"/dev/vda1","type":"part","size":8589934592,"fstype":"ext4","label":"nixos","uuid":"11111111-1111-1111-1111-111111111111","mountpoints":["/"]}]}`}, disks...)
	return []byte(`{"blockdevices":[` + strings.Join(all, ",") + `]}`)
}

func blank(name string, gibs int) string {
	return `{"name":"` + name + `","path":"/dev/` + name + `","type":"disk","size":` + itoa(gibs*gib) + `,"mountpoints":[null]}`
}

func itoa(n int) string { return strconv.Itoa(n) }

// btrfsMember: a disk carrying the pool's btrfs (uuid mirrorUUID); mounted when mount is set.
func btrfsMember(name string, gibs int, mounted bool) string {
	mounts := `[null]`
	if mounted {
		mounts = `["/var/lib/recasanix/data","/DATA"]`
	}
	return `{"name":"` + name + `","path":"/dev/` + name + `","type":"disk","size":` + itoa(gibs*gib) +
		`,"fstype":"btrfs","label":"recasanix-data","uuid":"` + mirrorUUID + `","mountpoints":` + mounts +
		`,"fssize":` + itoa(gibs*gib) + `,"fsused":1073741824,"fsavail":1073741824}`
}

type rig struct {
	t   *testing.T
	inv *Inventory
	run *fakeRunner
	sys *fakeSys
	k   *fakeBtrfs
	pl  *Planner
}

func newRig(t *testing.T, lsblk []byte) *rig {
	t.Helper()
	inv, run := testInventory(t, "vm-blank-disk.json", baseConfig(""))
	run.outputs[lsblkCall] = lsblk
	sys := newFakeSys(t)
	k := mirror()
	inv.sys, inv.btrfs = sys.root, k
	pl := newPlanner(inv, run, inv.cfg, discardLog())
	return &rig{t: t, inv: inv, run: run, sys: sys, k: k, pl: pl}
}

func (r *rig) view() *storageView {
	r.t.Helper()
	v, err := r.inv.view(context.Background())
	if err != nil {
		r.t.Fatal(err)
	}
	return v
}

func (r *rig) plan(in Intent) *Plan {
	r.t.Helper()
	p, err := r.pl.Plan(context.Background(), in)
	if err != nil {
		r.t.Fatalf("%+v: %v", in, err)
	}
	return p
}

func (r *rig) refused(in Intent, want string) {
	r.t.Helper()
	_, err := r.pl.Plan(context.Background(), in)
	var ref refusal
	if !errors.As(err, &ref) || !strings.Contains(ref.msg, want) {
		r.t.Fatalf("%+v: %v, want a refusal containing %q", in, err, want)
	}
}

// apply applies and waits for the job.
func (r *rig) apply(p *Plan, confirm string) *Job {
	r.t.Helper()
	j, err := r.pl.Apply(context.Background(), p.ID, confirm)
	if err != nil {
		r.t.Fatal(err)
	}
	for range 200 {
		if !r.pl.Busy() {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	for _, job := range r.pl.Jobs() {
		if job.ID == j.ID {
			return &job
		}
	}
	r.t.Fatal("job lost")
	return nil
}

func roles(v *storageView) map[string]string {
	m := map[string]string{}
	for _, d := range v.drives {
		m[d.Name] = d.Role
	}
	return m
}

var online = [][]string{
	{"udevadm", "settle", "--timeout=30"},
	{"mkdir", "-p", "--", "/var/lib/recasanix/data/DATA"},
	{"mountpoint", "-q", "--", "/var/lib/recasanix/data"},
	{"systemctl", "start", "--", "DATA.mount", "docker.service"},
	{"systemctl", "restart", "--", "casaos.service", "casaos-app-management.service"},
}

func TestRolesWithoutAPool(t *testing.T) {
	foreign := `{"name":"vde","path":"/dev/vde","type":"disk","size":8589934592,"mountpoints":[null],
	  "children":[{"name":"vde1","path":"/dev/vde1","type":"part","size":8589934592,"fstype":"ext4","uuid":"x","mountpoints":[null]}]}`
	busy := `{"name":"vdf","path":"/dev/vdf","type":"disk","size":8589934592,"fstype":"ext4","uuid":"y","mountpoints":["/var/lib/recasanix/state"]}`
	r := newRig(t, machine(blank("vdb", 8), blank("vdc", 8), blank("vdd", 0)+``, foreign, busy))
	r.run.outputs[lsblkCall] = []byte(strings.Replace(string(r.run.outputs[lsblkCall]), `"name":"vdd","path":"/dev/vdd","type":"disk","size":0`, `"name":"vdd","path":"/dev/vdd","type":"disk","size":536870912`, 1))
	v := r.view()
	want := map[string]string{"vda": "system", "vdb": "free", "vdc": "free", "vdd": "small", "vde": "foreign", "vdf": "busy"}
	if got := roles(v); !reflect.DeepEqual(got, want) {
		t.Fatalf("roles %v, want %v", got, want)
	}
	if v.pool != nil {
		t.Fatalf("pool %+v", v.pool)
	}
	if d := v.drive("vdb"); !reflect.DeepEqual(d.Verbs, []string{"create-pool"}) {
		t.Fatalf("free disk verbs %v", d.Verbs)
	}
	if d := v.drive("vde"); d.Content != "partitions" || !reflect.DeepEqual(d.Verbs, []string{"wipe-disk"}) {
		t.Fatalf("foreign %+v", d)
	}
}

func TestCreateMirror(t *testing.T) {
	r := newRig(t, machine(blank("vdb", 8), blank("vdc", 8)))
	p := r.plan(Intent{Verb: "create-pool", Layout: &Layout{Kind: "mirror", Copies: 2}, Disks: []string{"vdb", "vdc"}})
	want := append([][]string{{"mkfs.btrfs", "-f", "-L", "recasanix-data", "-d", "raid1", "-m", "raid1", "--", "/dev/vdb", "/dev/vdc"}}, online...)
	if !reflect.DeepEqual(p.Commands, want) {
		t.Fatalf("commands\n%q\nwant\n%q", p.Commands, want)
	}
	if p.Confirm != "vdb vdc" || p.Effects.CapacityAfter != 8*gib || p.Effects.ToleratesAfter != 1 || !reflect.DeepEqual(p.Effects.Erases, []string{"vdb", "vdc"}) {
		t.Fatalf("%+v", p)
	}

	// the confirmation must be typed; then exactly these commands run, in order
	if _, err := r.pl.Apply(context.Background(), p.ID, "vdb"); !errors.Is(err, errConfirm) {
		t.Fatalf("wrong confirmation: %v", err)
	}
	if n := r.run.count("mkfs"); n != 0 {
		t.Fatal("a refused apply ran mkfs")
	}
	before := len(r.run.calls)
	job := r.apply(p, "vdb vdc")
	if job.State != "done" || job.Step != len(want) {
		t.Fatalf("job %+v", job)
	}
	var ran []string
	for _, c := range r.run.calls[before:] {
		if !strings.HasPrefix(c, "lsblk") && !strings.HasPrefix(c, "smartctl") {
			ran = append(ran, c)
		}
	}
	var wantRan []string
	for _, c := range want {
		wantRan = append(wantRan, key(c[0], c[1:]...))
	}
	if !reflect.DeepEqual(ran, wantRan) {
		t.Fatalf("ran\n%q\nwant\n%q", ran, wantRan)
	}
	// a plan is applied once
	if _, err := r.pl.Apply(context.Background(), p.ID, "vdb vdc"); !errors.Is(err, errNoPlan) {
		t.Fatalf("second apply: %v", err)
	}
}

func TestCreateParityGoesToMD(t *testing.T) {
	r := newRig(t, machine(blank("vdb", 8), blank("vdc", 8), blank("vdd", 4)))
	r.refused(Intent{Verb: "create-pool", Layout: &Layout{Kind: "parity", Parity: 1}, Disks: []string{"vdb", "vdc"}}, "needs at least 3 disks")
	p := r.plan(Intent{Verb: "create-pool", Layout: &Layout{Kind: "parity", Parity: 1}, Disks: []string{"vdb", "vdc", "vdd"}})
	want := append([][]string{
		{"mdadm", "--create", "/dev/md/recasanix-data", "--name=recasanix-data", "--run", "--level=5", "--raid-devices=3", "--metadata=1.2", "/dev/vdb", "/dev/vdc", "/dev/vdd"},
		{"udevadm", "settle", "--timeout=30"},
		{"mkfs.btrfs", "-f", "-L", "recasanix-data", "-d", "single", "-m", "dup", "--", "/dev/md/recasanix-data"},
	}, online...)
	if !reflect.DeepEqual(p.Commands, want) {
		t.Fatalf("commands\n%q\nwant\n%q", p.Commands, want)
	}
	// raid5 holds (n-1) × the smallest disk
	if p.Effects.CapacityAfter != 8*gib || p.Effects.ToleratesAfter != 1 || !p.Effects.Background {
		t.Fatalf("%+v", p.Effects)
	}
}

func TestCreateRefusals(t *testing.T) {
	r := newRig(t, machine(blank("vdb", 8)))
	for _, c := range []struct {
		in   Intent
		want string
	}{
		{Intent{Verb: "create-pool", Disks: []string{"vdb"}}, "choose a layout"},
		{Intent{Verb: "create-pool", Layout: &Layout{Kind: "mirror", Copies: 7}, Disks: []string{"vdb"}}, "choose a layout"},
		{Intent{Verb: "create-pool", Layout: &Layout{Kind: "none"}, Disks: []string{"vda"}}, "the system disk"},
		{Intent{Verb: "create-pool", Layout: &Layout{Kind: "none"}, Disks: []string{"/dev/vdb"}}, "not a disk of this machine"},
		{Intent{Verb: "create-pool", Layout: &Layout{Kind: "none"}, Disks: []string{"vdb", "vdb"}}, "chosen twice"},
		{Intent{Verb: "create-pool", Layout: &Layout{Kind: "mirror", Copies: 2}, Disks: []string{"vdb"}}, "needs at least 2 disks"},
		{Intent{Verb: "add-disk", Disks: []string{"vdb"}}, "no pool yet"},
		{Intent{Verb: "format-everything"}, "no pool yet"},
	} {
		r.refused(c.in, c.want)
	}
}

func TestStalePlanIsNotApplied(t *testing.T) {
	r := newRig(t, machine(blank("vdb", 8), blank("vdc", 8)))
	p := r.plan(Intent{Verb: "create-pool", Layout: &Layout{Kind: "none"}, Disks: []string{"vdb", "vdc"}})
	// vdc got a filesystem meanwhile: the fresh plan differs (refused, even)
	r.run.outputs[lsblkCall] = machine(blank("vdb", 8), `{"name":"vdc","path":"/dev/vdc","type":"disk","size":8589934592,"fstype":"ext4","mountpoints":[null]}`)
	if _, err := r.pl.Apply(context.Background(), p.ID, "vdb vdc"); err == nil {
		t.Fatal("applied a plan whose disk changed")
	}
	// vdc replaced by a different disk at the same name: same commands, but a bigger one: still the same
	// plan by its commands — sizes are effects, not commands. A disk *path* change is what matters.
	r.run.outputs[lsblkCall] = machine(blank("vdb", 8))
	if _, err := r.pl.Apply(context.Background(), p.ID, "vdb vdc"); err == nil {
		t.Fatal("applied a plan whose disk is gone")
	}
	if r.run.count("mkfs") != 0 {
		t.Fatal("ran mkfs")
	}
}

// a mounted two-disk raid1 pool (sda, sdb from mirror-pool.json's uuid) plus a free disk sdc
func mirrorRig(t *testing.T, extra ...string) *rig {
	disks := append([]string{btrfsMember("sda", 8, false), btrfsMember("sdb", 8, true), blank("sdc", 8)}, extra...)
	r := newRig(t, machine(disks...))
	r.sys.fs(mirrorUUID, []int{1, 2}, map[string]uint64{"raid1": 4 * gib}, 2*gib)
	r.sys.block("sda", "sdb", "sdc")
	r.k.devs = map[uint64]fakeDev{1: {"/dev/sdb", 8 * gib}, 2: {"/dev/sda", 8 * gib}}
	return r
}

func TestMirrorPoolView(t *testing.T) {
	r := mirrorRig(t)
	v := r.view()
	p := v.pool
	if p == nil || p.Backend != "btrfs" || p.Layout != (Layout{Kind: "mirror", Copies: 2}) || !p.LayoutKnown || p.State != "ok" ||
		!p.Mounted || p.Tolerates != 1 || p.Disks != 2 || p.Size != 8*gib {
		t.Fatalf("pool %+v", p)
	}
	if want := []string{"add-disk", "replace-disk", "change-layout", "check"}; !reflect.DeepEqual(p.Verbs, want) {
		t.Fatalf("pool verbs %v, want %v (a 2-disk mirror cannot lose a disk)", p.Verbs, want)
	}
	if got := roles(v); got["sda"] != "member" || got["sdb"] != "member" || got["sdc"] != "free" {
		t.Fatalf("roles %v", got)
	}
}

func TestMirrorPoolVerbs(t *testing.T) {
	r := mirrorRig(t)
	mount := "/var/lib/recasanix/data"

	add := r.plan(Intent{Verb: "add-disk", Disks: []string{"sdc"}})
	if !reflect.DeepEqual(add.Commands, [][]string{{"btrfs", "device", "add", "-f", "--", "/dev/sdc", mount}}) || add.Effects.CapacityAfter != 12*gib {
		t.Fatalf("add %q %+v", add.Commands, add.Effects)
	}

	rep := r.plan(Intent{Verb: "replace-disk", Member: "sda", Disks: []string{"sdc"}})
	if !reflect.DeepEqual(rep.Commands, [][]string{{"btrfs", "replace", "start", "-f", "2", "/dev/sdc", mount}}) || rep.Confirm != "sdc" {
		t.Fatalf("replace %q", rep.Commands)
	}
	r.refused(Intent{Verb: "replace-disk", Member: "sdz", Disks: []string{"sdc"}}, "not a disk of the pool")
	r.refused(Intent{Verb: "replace-disk", Member: "sda", Disks: []string{"sdb"}}, "already in the pool")

	// fewer copies: typed confirmation, the pool's name
	conv := r.plan(Intent{Verb: "change-layout", Layout: &Layout{Kind: "none"}})
	if !reflect.DeepEqual(conv.Commands, [][]string{{"btrfs", "balance", "start", "--bg", "-f", "-dconvert=single", "-mconvert=raid1", mount}}) ||
		conv.Confirm != "recasanix-data" || conv.Effects.ToleratesAfter != 0 || conv.Effects.CapacityAfter != 16*gib {
		t.Fatalf("convert %q %+v %q", conv.Commands, conv.Effects, conv.Confirm)
	}
	r.refused(Intent{Verb: "change-layout", Layout: &Layout{Kind: "mirror", Copies: 3}}, "not possible with 2 disks")
	r.refused(Intent{Verb: "change-layout", Layout: &Layout{Kind: "parity", Parity: 1}}, "needs a new pool")
	r.refused(Intent{Verb: "remove-disk", Member: "sda"}, "needs at least 2 disks")

	check := r.plan(Intent{Verb: "check"})
	if !reflect.DeepEqual(check.Commands, [][]string{{"btrfs", "scrub", "start", mount}}) || check.Confirm != "" {
		t.Fatalf("check %q", check.Commands)
	}
}

func TestThreeDiskMirrorCanLoseOne(t *testing.T) {
	r := mirrorRig(t, btrfsMember("sdd", 8, false))
	dir := r.sys.fs(mirrorUUID, []int{1, 2, 3}, map[string]uint64{"raid1": 4 * gib}, 2*gib)
	_ = dir
	r.sys.block("sdd")
	r.k.devs[3] = fakeDev{"/dev/sdd", 8 * gib}
	p := r.plan(Intent{Verb: "remove-disk", Member: "sdd"})
	if !reflect.DeepEqual(p.Commands, [][]string{{"btrfs", "device", "remove", "3", "/var/lib/recasanix/data"}}) || p.Confirm != "sdd" {
		t.Fatalf("remove %q", p.Commands)
	}
}

func TestDegradedMirror(t *testing.T) {
	// mounted -o degraded, devid 2 has no device: replace it by its id
	r := newRig(t, machine(btrfsMember("sdb", 8, true), blank("sdc", 8)))
	dir := r.sys.fs(mirrorUUID, []int{1, 2}, map[string]uint64{"raid1": 4 * gib}, 2*gib)
	r.sys.write(filepath.Join(dir, "devinfo", "2", "missing"), "1")
	r.sys.block("sdb", "sdc")
	r.k.devs = map[uint64]fakeDev{1: {"/dev/sdb", 8 * gib}, 2: {"", 0}}
	v := r.view()
	if v.pool.State != "degraded" || v.pool.Tolerates != 0 || v.pool.Missing != 1 {
		t.Fatalf("pool %+v", v.pool)
	}
	p := r.plan(Intent{Verb: "replace-disk", Member: "devid 2", Disks: []string{"sdc"}})
	// then what was written meanwhile (one copy) gets its copies back
	if !reflect.DeepEqual(p.Commands, [][]string{
		{"btrfs", "replace", "start", "-f", "2", "/dev/sdc", "/var/lib/recasanix/data"},
		{"btrfs", "balance", "start", "--bg", "-dconvert=raid1,soft", "-mconvert=raid1,soft", "/var/lib/recasanix/data"},
	}) || p.Effects.ToleratesAfter != 1 {
		t.Fatalf("replace missing %q %+v", p.Commands, p.Effects)
	}
}

func TestUnmountedMirrorMissingADisk(t *testing.T) {
	r := newRig(t, machine(btrfsMember("sdb", 8, false), blank("sdc", 8)))
	r.sys.block("sdb", "sdc")
	r.k.devices = map[string]uint64{"/dev/sdb": 2}
	v := r.view()
	if v.pool == nil || v.pool.State != "inactive" || v.pool.Mounted || !reflect.DeepEqual(v.pool.Verbs, []string{"mount-degraded"}) {
		t.Fatalf("pool %+v", v.pool)
	}
	p := r.plan(Intent{Verb: "mount-degraded"})
	want := append([][]string{
		{"systemctl", "stop", "--", `var-lib-recasanix-data.automount`},
		{"mount", "-t", "btrfs", "-o", "degraded,noatime,compress=zstd", "--", "/dev/sdb", "/var/lib/recasanix/data"},
	}, online[1:]...)
	if !reflect.DeepEqual(p.Commands, want) || p.Confirm != "recasanix-data" {
		t.Fatalf("mount degraded\n%q\nwant\n%q", p.Commands, want)
	}
	r.refused(Intent{Verb: "add-disk", Disks: []string{"sdc"}}, "not mounted")
}

func TestAutomountUnitIsSystemdEscaped(t *testing.T) {
	for in, want := range map[string]string{
		"/var/lib/recasanix/data": "var-lib-recasanix-data.automount",
		"/srv/my-pool":            `srv-my\x2dpool.automount`,
	} {
		if got := automountUnit(in); got != want {
			t.Errorf("%s: %s, want %s", in, got, want)
		}
	}
}

// a raid5 md pool on vdb, vdc, vdd (md127), btrfs on it, mounted; vde free
func mdRig(t *testing.T, faulty bool) *rig {
	t.Helper()
	md := `{"name":"md127","path":"/dev/md127","type":"raid5","size":17179869184,"fstype":"btrfs","label":"recasanix-data","uuid":"` + mirrorUUID +
		`","mountpoints":["/var/lib/recasanix/data","/DATA"],"fssize":17179869184,"fsused":1073741824,"fsavail":16106127360}`
	member := func(name string) string {
		return `{"name":"` + name + `","path":"/dev/` + name + `","type":"disk","size":8589934592,"fstype":"linux_raid_member","label":"box:recasanix-data","uuid":"m","mountpoints":[null],"children":[` + md + `]}`
	}
	r := newRig(t, machine(member("vdb"), member("vdc"), member("vdd"), blank("vde", 8)))
	dir := filepath.Join("block", "md127", "md")
	for f, v := range map[string]string{"level": "raid5", "raid_disks": "3", "degraded": "0", "component_size": "8388608", "array_state": "clean", "sync_action": "idle", "sync_completed": "none"} {
		r.sys.write(filepath.Join(dir, f), v)
	}
	for i, n := range []string{"vdb", "vdc", "vdd"} {
		state := "in_sync"
		if faulty && n == "vdc" {
			state = "faulty"
		}
		r.sys.write(filepath.Join(dir, "dev-"+n, "state"), state)
		r.sys.write(filepath.Join(dir, "dev-"+n, "slot"), itoa(i))
		r.sys.write(filepath.Join(dir, "dev-"+n, "errors"), "0")
	}
	r.sys.block("vdb", "vdc", "vdd", "vde")
	return r
}

func TestParityPool(t *testing.T) {
	r := mdRig(t, false)
	v := r.view()
	p := v.pool
	if p == nil || p.Backend != "md" || p.Layout != (Layout{Kind: "parity", Parity: 1}) || p.State != "ok" || p.Tolerates != 1 || len(p.Members) != 3 {
		t.Fatalf("pool %+v", p)
	}
	if got := roles(v); got["vdb"] != "member" || got["vde"] != "free" {
		t.Fatalf("roles %v", got)
	}
	if want := []string{"add-disk", "replace-disk", "check"}; !reflect.DeepEqual(p.Verbs, want) {
		t.Fatalf("verbs %v, want %v", p.Verbs, want)
	}
	add := r.plan(Intent{Verb: "add-disk", Disks: []string{"vde"}})
	want := [][]string{
		{"mdadm", "--add", "/dev/md127", "/dev/vde"},
		{"mdadm", "--grow", "/dev/md127", "--raid-devices=4"},
		{"btrfs", "filesystem", "resize", "max", "/var/lib/recasanix/data"},
	}
	if !reflect.DeepEqual(add.Commands, want) || add.Effects.CapacityAfter != 24*gib || !add.Effects.Background {
		t.Fatalf("add %q %+v", add.Commands, add.Effects)
	}
	// a working disk is replaced while the pool keeps its protection
	rep := r.plan(Intent{Verb: "replace-disk", Member: "vdc", Disks: []string{"vde"}})
	if !reflect.DeepEqual(rep.Commands, [][]string{
		{"mdadm", "--add", "/dev/md127", "/dev/vde"},
		{"mdadm", "--replace", "/dev/md127", "/dev/vdc", "--with", "/dev/vde"},
	}) {
		t.Fatalf("replace %q", rep.Commands)
	}
	check := r.plan(Intent{Verb: "check"})
	if !reflect.DeepEqual(check.Commands, [][]string{{"mdadm", "--action=check", "/dev/md127"}}) {
		t.Fatalf("check %q", check.Commands)
	}
}

func TestParityPoolWithAFailedDisk(t *testing.T) {
	r := mdRig(t, true)
	v := r.view()
	if v.pool.State != "degraded" || !strings.Contains(strings.Join(v.pool.Verbs, " "), "remove-disk") {
		t.Fatalf("pool %+v", v.pool)
	}
	rep := r.plan(Intent{Verb: "replace-disk", Member: "vdc", Disks: []string{"vde"}})
	if !reflect.DeepEqual(rep.Commands, [][]string{
		{"mdadm", "/dev/md127", "--fail", "/dev/vdc", "--remove", "/dev/vdc"},
		{"mdadm", "--add", "/dev/md127", "/dev/vde"},
	}) {
		t.Fatalf("replace failed %q", rep.Commands)
	}
	r.refused(Intent{Verb: "remove-disk", Member: "vdb"}, "only a failed or spare disk")
	rm := r.plan(Intent{Verb: "remove-disk", Member: "vdc"})
	if !reflect.DeepEqual(rm.Commands, [][]string{
		{"mdadm", "/dev/md127", "--fail", "/dev/vdc", "--remove", "/dev/vdc"},
		{"mdadm", "--zero-superblock", "/dev/vdc"},
	}) {
		t.Fatalf("remove %q", rm.Commands)
	}
}

func TestV1CreateRefusesAParityPool(t *testing.T) {
	r := mdRig(t, false)
	if err := newCreator(r.run, r.inv.cfg).Create(context.Background(), "/dev/vde"); !errors.Is(err, errPoolOnMD) {
		t.Fatalf("v1 create on a parity pool: %v", err)
	}
	if r.run.count("btrfs device add") != 0 {
		t.Fatal("added a raw disk to the filesystem on md")
	}
}

func TestWipeForeignDisk(t *testing.T) {
	foreign := `{"name":"vde","path":"/dev/vde","type":"disk","size":8589934592,"mountpoints":[null],
	  "children":[{"name":"vde1","path":"/dev/vde1","type":"part","size":8589934592,"fstype":"linux_raid_member","uuid":"x","mountpoints":[null]}]}`
	r := newRig(t, machine(foreign))
	p := r.plan(Intent{Verb: "wipe-disk", Disks: []string{"vde"}})
	want := [][]string{
		{"mdadm", "--zero-superblock", "/dev/vde1"},
		{"wipefs", "-a", "--", "/dev/vde1"},
		{"wipefs", "-a", "--", "/dev/vde"},
		{"udevadm", "settle", "--timeout=30"},
	}
	if !reflect.DeepEqual(p.Commands, want) || p.Confirm != "vde" {
		t.Fatalf("wipe %q", p.Commands)
	}
	r.refused(Intent{Verb: "wipe-disk", Disks: []string{"vda"}}, "the system disk")
}

func TestOneJobAtATime(t *testing.T) {
	r := newRig(t, machine(blank("vdb", 8), blank("vdc", 8)))
	p1 := r.plan(Intent{Verb: "create-pool", Layout: &Layout{Kind: "none"}, Disks: []string{"vdb"}})
	p2 := r.plan(Intent{Verb: "create-pool", Layout: &Layout{Kind: "none"}, Disks: []string{"vdc"}})
	r.pl.mu.Lock()
	r.pl.busy = true
	r.pl.mu.Unlock()
	if _, err := r.pl.Apply(context.Background(), p1.ID, "vdb"); !errors.Is(err, errBusy) {
		t.Fatalf("busy: %v", err)
	}
	_ = p2
}

func TestStorageRoutes(t *testing.T) {
	r := newRig(t, machine(blank("vdb", 8), blank("vdc", 8)))
	priv := newKey(t)
	api := &API{inv: r.inv, creator: newCreator(r.run, r.inv.cfg), planner: r.pl, log: discardLog()}
	h := newAuthenticator(staticKey{key: &priv.PublicKey}).Middleware(api.Handler())
	bearer := "Bearer " + token(t, priv, tokenOpts{issuer: "casaos", expires: in(time.Hour)})

	send := func(method, target, body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, target, strings.NewReader(body))
		req.Header.Set("Authorization", bearer)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		return w
	}
	w := send("GET", "/v2/storage", "")
	m := decode(t, w)
	data := m["data"].(map[string]any)
	if w.Code != 200 || data["pool"] != nil || len(data["drives"].([]any)) != 3 || len(data["layouts"].([]any)) != len(layouts) {
		t.Fatalf("%d %v", w.Code, m)
	}
	w = send("GET", "/v2/storage/layouts?disks=vdb,vdc,vda,vdb", "")
	opts := decode(t, w)["data"].([]any)
	mirror := opts[1].(map[string]any)
	if mirror["possible"] != true || mirror["capacity"].(float64) != 8*gib {
		t.Fatalf("layouts %v", opts)
	}
	if parity := opts[3].(map[string]any); parity["possible"] != false || parity["reason"] != "needs at least 3 disks" {
		t.Fatalf("parity %v", parity)
	}
	w = send("POST", "/v2/storage/plans", `{"verb":"create-pool","layout":{"kind":"mirror","copies":2},"disks":["vdb","vda"]}`)
	if w.Code != http.StatusConflict || !strings.Contains(decode(t, w)["message"].(string), "system disk") {
		t.Fatalf("refusal %d %s", w.Code, w.Body)
	}
	w = send("POST", "/v2/storage/plans", `{"verb":"create-pool","layout":{"kind":"mirror","copies":2},"disks":["vdb","vdc"]}`)
	plan := decode(t, w)["data"].(map[string]any)
	if w.Code != 200 || plan["confirm"] != "vdb vdc" {
		t.Fatalf("plan %d %v", w.Code, plan)
	}
	id := plan["id"].(string)
	if w = send("POST", "/v2/storage/plans/"+id+"/apply", `{"confirm":"nope"}`); w.Code != http.StatusBadRequest {
		t.Fatalf("wrong confirm %d", w.Code)
	}
	if w = send("POST", "/v2/storage/plans/"+id+"/apply", `{"confirm":"vdb vdc"}`); w.Code != http.StatusAccepted {
		t.Fatalf("apply %d %s", w.Code, w.Body)
	}
	if w = send("POST", "/v2/storage/plans/unknown/apply", `{"confirm":""}`); w.Code != http.StatusNotFound {
		t.Fatalf("unknown plan %d", w.Code)
	}
	for r.pl.Busy() {
		time.Sleep(5 * time.Millisecond)
	}
	if jobs := decode(t, send("GET", "/v2/storage/jobs", ""))["data"].([]any); len(jobs) != 1 || jobs[0].(map[string]any)["state"] != "done" {
		t.Fatalf("jobs %v", jobs)
	}
}

func TestDataWrittenWithADiskMissing(t *testing.T) {
	// both disks there again, but part of the data is single: the pool is not protected until restored
	r := mirrorRig(t)
	r.sys.fs(mirrorUUID, []int{1, 2}, map[string]uint64{"raid1": 4 * gib, "single": 1 * gib}, 2*gib)
	p := r.view().pool
	if p.State != "degraded" || p.Tolerates != 0 || p.Problem == "" || !strings.Contains(strings.Join(p.Verbs, " "), "restore-layout") {
		t.Fatalf("pool %+v", p)
	}
	plan := r.plan(Intent{Verb: "restore-layout"})
	if !reflect.DeepEqual(plan.Commands, [][]string{{"btrfs", "balance", "start", "--bg", "-dconvert=raid1,soft", "-mconvert=raid1,soft", "/var/lib/recasanix/data"}}) ||
		plan.Confirm != "" || plan.Effects.ToleratesAfter != 1 {
		t.Fatalf("restore %q %+v", plan.Commands, plan.Effects)
	}
}

func TestParityPoolNotStarted(t *testing.T) {
	// assembled at boot with a member missing: inactive, no level, the members spares; its filesystem unseen
	member := func(name string) string {
		return `{"name":"` + name + `","path":"/dev/` + name + `","type":"disk","size":8589934592,"fstype":"linux_raid_member","label":"box:recasanix-data","uuid":"m","mountpoints":[null]}`
	}
	r := newRig(t, machine(member("vdd"), member("vde"), blank("vdb", 8)))
	dir := filepath.Join("block", "md127", "md")
	r.sys.write(filepath.Join(dir, "level"), "")
	r.sys.write(filepath.Join(dir, "array_state"), "inactive")
	r.sys.write(filepath.Join(dir, "raid_disks"), "0")
	for _, n := range []string{"vdd", "vde"} {
		r.sys.write(filepath.Join(dir, "dev-"+n, "state"), "spare")
		r.sys.write(filepath.Join(dir, "dev-"+n, "slot"), "none")
	}
	r.sys.block("vdd", "vde", "vdb")
	v := r.view()
	p := v.pool
	if p == nil || p.Backend != "md" || p.State != "inactive" || p.Mounted || !reflect.DeepEqual(p.Verbs, []string{"mount-degraded"}) {
		t.Fatalf("pool %+v", p)
	}
	if got := roles(v); got["vdd"] != "member" || got["vdb"] != "free" {
		t.Fatalf("roles %v", got)
	}
	plan := r.plan(Intent{Verb: "mount-degraded"})
	if plan.Commands[0][0] != "mdadm" || !reflect.DeepEqual(plan.Commands[0], []string{"mdadm", "--run", "/dev/md127"}) {
		t.Fatalf("mount degraded %q", plan.Commands)
	}
}
