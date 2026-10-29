package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

// mirror-pool.json: sda + sdb, one btrfs, mounted (lsblk shows it on sdb)
const mirrorUUID = "7c9e1b2a-0000-4000-8000-000000000002"

// fakeSys is a sysfs tree in a temporary directory.
type fakeSys struct {
	t    *testing.T
	root string
}

func newFakeSys(t *testing.T) *fakeSys { return &fakeSys{t: t, root: t.TempDir()} }

func (s *fakeSys) write(rel, content string) {
	s.t.Helper()
	p := filepath.Join(s.root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		s.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content+"\n"), 0o644); err != nil {
		s.t.Fatal(err)
	}
}

// fs: a mounted btrfs with these devids, data profile(s) and bytes used on disk.
func (s *fakeSys) fs(uuid string, devids []int, profiles map[string]uint64, diskUsed uint64) string {
	dir := filepath.Join("fs", "btrfs", uuid)
	for _, id := range devids {
		d := filepath.Join(dir, "devinfo", strconv.Itoa(id))
		s.write(filepath.Join(d, "missing"), "0")
		s.write(filepath.Join(d, "replace_target"), "0")
		s.write(filepath.Join(d, "error_stats"), "write_errs 0\nread_errs 0\nflush_errs 0\ncorruption_errs 0\ngeneration_errs 0")
	}
	for p, total := range profiles {
		s.write(filepath.Join(dir, "allocation", "data", p, "total_bytes"), strconv.FormatUint(total, 10))
	}
	s.write(filepath.Join(dir, "allocation", "data", "disk_used"), strconv.FormatUint(diskUsed, 10))
	s.write(filepath.Join(dir, "allocation", "metadata", "disk_used"), "0")
	s.write(filepath.Join(dir, "allocation", "system", "disk_used"), "0")
	s.write(filepath.Join(dir, "exclusive_operation"), "none")
	return dir
}

// block: a whole disk present under class/block.
func (s *fakeSys) block(names ...string) {
	for _, n := range names {
		if err := os.MkdirAll(filepath.Join(s.root, "class", "block", n), 0o755); err != nil {
			s.t.Fatal(err)
		}
	}
}

type fakeDev struct {
	path string
	size uint64
}

type fakeBtrfs struct {
	devs     map[uint64]fakeDev
	scrub    map[uint64]uint64 // devid → bytes scrubbed, while running
	replace  int64             // permille; -1 = none
	devices  map[string]uint64 // superblock device counts
	mountsAt []string
}

func (f *fakeBtrfs) Devices(dev string) (uint64, error) {
	if n, ok := f.devices[dev]; ok {
		return n, nil
	}
	return 0, errNotBtrfs
}

func (f *fakeBtrfs) DevInfo(mount string, devid uint64) (string, uint64, error) {
	f.mountsAt = append(f.mountsAt, mount)
	d, ok := f.devs[devid]
	if !ok {
		return "", 0, os.ErrNotExist
	}
	return d.path, d.size, nil
}

func (f *fakeBtrfs) ScrubProgress(_ string, devid uint64) (bool, uint64, error) {
	n, ok := f.scrub[devid]
	return ok, n, nil
}

func (f *fakeBtrfs) ReplaceProgress(string) (bool, uint64, error) {
	if f.replace < 0 {
		return false, 0, nil
	}
	return true, uint64(f.replace), nil
}

const gib = 1 << 30

func mirror() *fakeBtrfs {
	return &fakeBtrfs{
		devs:    map[uint64]fakeDev{1: {"/dev/sdb", 8 * gib}, 2: {"/dev/sda", 8 * gib}},
		scrub:   map[uint64]uint64{},
		replace: -1,
	}
}

func raidInventory(t *testing.T, lsblk string, sys *fakeSys, k *fakeBtrfs) *Inventory {
	t.Helper()
	inv, _ := testInventory(t, lsblk, baseConfig(""))
	inv.sys, inv.btrfs = sys.root, k
	return inv
}

// asJSON is what the API shows of v.
func asJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

func onlyArray(t *testing.T, inv *Inventory) RAIDArray {
	t.Helper()
	arrays, err := inv.RAID(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(arrays) != 1 {
		t.Fatalf("want one array, got %+v", arrays)
	}
	return arrays[0]
}

func TestRAIDMirrorHealthy(t *testing.T) {
	sys := newFakeSys(t)
	sys.fs(mirrorUUID, []int{1, 2}, map[string]uint64{"raid1": 4 * gib}, 2*gib)
	sys.block("sda", "sdb")
	k := mirror()
	k.devs[2] = fakeDev{"/dev/sda", 7 * gib}
	a := onlyArray(t, raidInventory(t, "mirror-pool.json", sys, k))

	want := RAIDArray{
		Name: "recasanix-data", Path: "/dev/sdb", Level: "raid1", State: "ok", Disks: 2, Missing: 0,
		ComponentSize: 7 * gib, Action: "idle", Progress: -1, Remaining: -1,
		Members: []RAIDMember{{Name: "sdb", Disk: "sdb", State: "active"}, {Name: "sda", Disk: "sda", State: "active"}},
	}
	if asJSON(a) != asJSON(want) {
		t.Fatalf("got  %+v\nwant %+v", a, want)
	}
	// the UI attaches the array to the storage listed under the same disk path
	storage, err := raidInventory(t, "mirror-pool.json", sys, mirror()).Storage(context.Background(), false)
	if err != nil || len(storage) != 1 || storage[0].Path != a.Path {
		t.Fatalf("array path %s, storage %+v (%v)", a.Path, storage, err)
	}
	// ioctls go to where the pool is mounted, the data root preferred
	for _, m := range k.mountsAt {
		if m != "/DATA" {
			t.Fatalf("ioctl on %q", m)
		}
	}
}

func TestRAIDDegradedMount(t *testing.T) {
	// mounted -o degraded: the kernel marks the absent member missing and has no path for it
	sys := newFakeSys(t)
	dir := sys.fs(mirrorUUID, []int{1, 2}, map[string]uint64{"raid1": 4 * gib}, 2*gib)
	sys.write(filepath.Join(dir, "devinfo", "2", "missing"), "1")
	sys.block("sdb")
	k := mirror()
	k.devs[2] = fakeDev{"<missing disk>", 0} // what the kernel says for it
	k.scrub[1] = gib                         // a scrub does not hide that a disk is missing
	a := onlyArray(t, raidInventory(t, "mirror-pool.json", sys, k))

	if a.State != "degraded" || a.Missing != 1 || a.Disks != 2 || a.ComponentSize != 8*gib {
		t.Fatalf("%+v", a)
	}
	if asJSON(a.Members[1]) != asJSON(RAIDMember{Name: "devid 2", State: "faulty"}) {
		t.Fatalf("missing member: %+v", a.Members[1])
	}
}

func TestRAIDMemberUnpluggedWhileMounted(t *testing.T) {
	// unplugged while mounted: devinfo stays (missing = 0), the block device is gone, errors count up
	sys := newFakeSys(t)
	dir := sys.fs(mirrorUUID, []int{1, 2}, map[string]uint64{"raid1": 4 * gib}, 2*gib)
	sys.write(filepath.Join(dir, "devinfo", "2", "error_stats"), "write_errs 75849\nread_errs 0\nflush_errs 31\ncorruption_errs 0\ngeneration_errs 0")
	sys.block("sdb")
	a := onlyArray(t, raidInventory(t, "mirror-pool.json", sys, mirror()))

	if a.State != "degraded" || a.Missing != 1 {
		t.Fatalf("%+v", a)
	}
	if asJSON(a.Members[1]) != asJSON(RAIDMember{Name: "sda", State: "faulty", Errors: 75880}) {
		t.Fatalf("unplugged member: %+v", a.Members[1])
	}
}

func TestRAIDReplaceRunning(t *testing.T) {
	sys := newFakeSys(t)
	dir := sys.fs(mirrorUUID, []int{0, 1, 2}, map[string]uint64{"raid1": 4 * gib}, 2*gib)
	sys.write(filepath.Join(dir, "devinfo", "0", "replace_target"), "1")
	sys.write(filepath.Join(dir, "exclusive_operation"), "device replace")
	sys.block("sda", "sdb", "sdc")
	k := mirror()
	k.devs[0] = fakeDev{"/dev/sdc", 16 * gib}
	k.replace = 229
	a := onlyArray(t, raidInventory(t, "mirror-pool.json", sys, k))

	if a.State != "rebuilding" || a.Action != "recover" || a.Progress != 22.9 || a.Disks != 2 || a.ComponentSize != 8*gib {
		t.Fatalf("%+v", a)
	}
	if asJSON(a.Members[0]) != asJSON(RAIDMember{Name: "sdc", Disk: "sdc", State: "rebuilding"}) {
		t.Fatalf("replace target: %+v", a.Members[0])
	}
}

func TestRAIDScrubRunning(t *testing.T) {
	sys := newFakeSys(t)
	sys.fs(mirrorUUID, []int{1, 2}, map[string]uint64{"raid1": 4 * gib}, 2*gib)
	sys.block("sda", "sdb")
	k := mirror()
	k.scrub[1], k.scrub[2] = gib/2, gib/2
	a := onlyArray(t, raidInventory(t, "mirror-pool.json", sys, k))

	if a.State != "checking" || a.Action != "check" || a.Progress != 50 {
		t.Fatalf("%+v", a)
	}
}

func TestRAIDReshaping(t *testing.T) {
	for name, tc := range map[string]struct {
		op       string
		profiles map[string]uint64
		level    string
	}{
		"balance":        {"balance", map[string]uint64{"raid1": 4 * gib}, "raid1"},
		"paused balance": {"balance paused", map[string]uint64{"raid1": 4 * gib}, "raid1"},
		"device remove":  {"device remove", map[string]uint64{"single": 4 * gib}, "single"},
	} {
		t.Run(name, func(t *testing.T) {
			sys := newFakeSys(t)
			dir := sys.fs(mirrorUUID, []int{1, 2}, tc.profiles, 2*gib)
			sys.write(filepath.Join(dir, "exclusive_operation"), tc.op)
			sys.block("sda", "sdb")
			a := onlyArray(t, raidInventory(t, "mirror-pool.json", sys, mirror()))
			if a.State != "reshaping" || a.Action != "reshape" || a.Level != tc.level {
				t.Fatalf("%+v", a)
			}
		})
	}
}

// two data profiles, no operation: the disks are whole (ok); the pool says the data is not (pools.go)
func TestRAIDMixedProfilesAreWholeDisks(t *testing.T) {
	for profiles, level := range map[[2]uint64]string{{3 * gib, 1 * gib}: "single", {1 * gib, 3 * gib}: "raid1"} {
		sys := newFakeSys(t)
		sys.fs(mirrorUUID, []int{1, 2}, map[string]uint64{"single": profiles[0], "raid1": profiles[1]}, 2*gib)
		sys.block("sda", "sdb")
		a := onlyArray(t, raidInventory(t, "mirror-pool.json", sys, mirror()))
		if a.State != "ok" || a.Action != "idle" || a.Level != level || !a.mixed {
			t.Fatalf("%v: %+v", profiles, a)
		}
	}
}

func TestRAIDJBODIsSingle(t *testing.T) {
	sys := newFakeSys(t)
	sys.fs(mirrorUUID, []int{1, 2}, map[string]uint64{"single": 8 * gib}, 2*gib)
	sys.block("sda", "sdb")
	a := onlyArray(t, raidInventory(t, "mirror-pool.json", sys, mirror()))
	if a.Level != "single" || a.State != "ok" {
		t.Fatalf("%+v", a)
	}
}

func TestRAIDSingleDeviceIsNoArray(t *testing.T) {
	sys := newFakeSys(t)
	sys.fs(mirrorUUID, []int{1}, map[string]uint64{"single": 8 * gib}, 2*gib)
	sys.block("sda", "sdb")
	arrays, err := raidInventory(t, "mirror-pool.json", sys, mirror()).RAID(context.Background())
	if err != nil || arrays == nil || len(arrays) != 0 {
		t.Fatalf("%#v %v", arrays, err)
	}
}

// one member of a two-device btrfs left, not mounted (a mirror needs `degraded` to mount then)
const unmountedHalf = `{"blockdevices": [
  {"name":"sdb","path":"/dev/sdb","type":"disk","size":8589934592,"fstype":"btrfs","label":"recasanix-data","uuid":"` + mirrorUUID + `","mountpoints":[null],"tran":"sata","rota":true}
]}`

func TestRAIDUnmountedMemberMissing(t *testing.T) {
	sys := newFakeSys(t)
	sys.block("sdb")
	k := mirror()
	k.devices = map[string]uint64{"/dev/sdb": 2}
	inv, run := testInventory(t, "mirror-pool.json", baseConfig(""))
	run.outputs[lsblkCall] = []byte(unmountedHalf)
	inv.sys, inv.btrfs = sys.root, k
	a := onlyArray(t, inv)

	want := RAIDArray{
		Name: "recasanix-data", Path: "/dev/sdb", Level: "", State: "inactive", Disks: 2, Missing: 1,
		ComponentSize: 8 * gib, Action: "idle", Progress: -1, Remaining: -1,
		Members: []RAIDMember{{Name: "sdb", Disk: "sdb", State: "active"}},
	}
	if asJSON(a) != asJSON(want) {
		t.Fatalf("got  %+v\nwant %+v", a, want)
	}

	// all its devices there, just not mounted: not an array in trouble, not listed
	k.devices["/dev/sdb"] = 1
	if arrays, _ := inv.RAID(context.Background()); len(arrays) != 0 {
		t.Fatalf("%+v", arrays)
	}
}

func TestRAIDPartitionMemberIsOnItsDisk(t *testing.T) {
	sys := newFakeSys(t)
	real := filepath.Join(sys.root, "devices", "pci0", "block", "sdb", "sdb1")
	sys.write(filepath.Join("devices", "pci0", "block", "sdb", "sdb1", "partition"), "1")
	if err := os.MkdirAll(filepath.Join(sys.root, "class", "block"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, filepath.Join(sys.root, "class", "block", "sdb1")); err != nil {
		t.Fatal(err)
	}
	if got := diskOf(sys.root, "sdb1"); got != "sdb" {
		t.Fatalf("diskOf(sdb1) = %q", got)
	}
}

func TestSuperblockDevices(t *testing.T) {
	img := filepath.Join(t.TempDir(), "dev")
	buf := make([]byte, superblockOffset+0x1000)
	copy(buf[superblockOffset+0x40:], superblockMagic)
	binary.LittleEndian.PutUint64(buf[superblockOffset+0x88:], 3)
	if err := os.WriteFile(img, buf, 0o600); err != nil {
		t.Fatal(err)
	}
	if n, err := superblockDevices(img); err != nil || n != 3 {
		t.Fatalf("%d %v", n, err)
	}
	if err := os.WriteFile(img, make([]byte, superblockOffset+0x1000), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := superblockDevices(img); err != errNotBtrfs {
		t.Fatalf("no magic: %v", err)
	}
}

func TestRAIDRoutes(t *testing.T) {
	h, run, bearer := testServerWithCreator(t, "mirror-pool.json")
	if w := do(h, "GET", "/v1/disks/raid", ""); w.Code != http.StatusUnauthorized {
		t.Fatalf("no token: %d", w.Code)
	}
	w := do(h, "GET", "/v1/disks/raid", bearer)
	if m := decode(t, w); w.Code != http.StatusOK || !reflect.DeepEqual(m["data"], []any{}) {
		t.Fatalf("%d %v: no btrfs in this sysfs, want an empty list", w.Code, m)
	}
	// repair is refused, says why, and runs nothing
	before := run.count("")
	for _, c := range []struct{ method, target string }{
		{"POST", "/v1/disks/raid/recasanix-data/disks"},
		{"DELETE", "/v1/disks/raid/recasanix-data/disks/sda"},
	} {
		w := do(h, c.method, c.target, bearer)
		if m := decode(t, w); w.Code != http.StatusNotImplemented || !strings.Contains(m["message"].(string), "not available yet") {
			t.Errorf("%s %s: %d %v", c.method, c.target, w.Code, m)
		}
	}
	if n := run.count(""); n != before {
		t.Fatalf("repair ran %d commands", n-before)
	}
}
