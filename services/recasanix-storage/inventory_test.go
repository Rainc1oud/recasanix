package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writeFstab(t *testing.T, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "fstab")
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func driveByName(t *testing.T, list []Drive, name string) Drive {
	t.Helper()
	for _, d := range list {
		if d.Name == name {
			return d
		}
	}
	t.Fatalf("no drive %q in %+v", name, list)
	return Drive{}
}

func names(list []Drive) []string {
	out := []string{}
	for _, d := range list {
		out = append(out, d.Name)
	}
	return out
}

func TestParseLsblkAcceptsOlderValueTypes(t *testing.T) {
	// util-linux before 2.37: sizes as strings, booleans as "0"/"1", a single mountpoint.
	old := []byte(`{"blockdevices":[{"name":"sda","path":"/dev/sda","type":"disk","size":"8589934592","rota":"1","rm":"0","fstype":"ext4","mountpoint":"/mnt/x","fssize":"100","fsavail":"40","fsused":"60"}]}`)
	blocks, err := parseLsblk(old)
	if err != nil {
		t.Fatal(err)
	}
	b := blocks[0]
	if b.Size != 8589934592 || !b.Rotational || b.Removable || b.FSAvail != 40 || len(b.Mounts) != 1 || b.Mounts[0] != "/mnt/x" {
		t.Fatalf("unexpected parse: %+v", b)
	}
}

func TestParseLsblkRejectsGarbage(t *testing.T) {
	if _, err := parseLsblk([]byte(`not json`)); err == nil {
		t.Fatal("garbage was accepted")
	}
	if _, err := parseLsblk([]byte(`{"blockdevices":[{"size":"lots"}]}`)); err == nil {
		t.Fatal("a size that is not a number was accepted")
	}
}

func TestLsblkIsRunAsAnArgumentVector(t *testing.T) {
	inv, run := testInventory(t, "vm-blank-disk.json", baseConfig(""))
	if _, _, err := inv.Disks(context.Background()); err != nil {
		t.Fatal(err)
	}
	if run.count("lsblk --json --bytes --output ") != 1 {
		t.Fatalf("lsblk was not run exactly as specified: %v", run.calls)
	}
}

func TestDisksOnAVMWithABlankDisk(t *testing.T) {
	inv, _ := testInventory(t, "vm-blank-disk.json", baseConfig(""))
	disks, avail, err := inv.Disks(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	// loop devices and the CD-ROM are not disks a user cares about
	if got := names(disks); len(got) != 3 || got[0] != "vda" || got[1] != "vdb" || got[2] != "vdc" {
		t.Fatalf("disks = %v", got)
	}

	sys := driveByName(t, disks, "vda")
	if sys.Model != "System" || sys.NeedFormat {
		t.Fatalf("system disk = %+v", sys)
	}
	if sys.ChildrenNumber != 2 || len(sys.Children) != 2 || sys.Children[1].Format != "ext4" || !sys.Supported {
		t.Fatalf("system disk children = %+v", sys.Children)
	}

	// the blank disk is the only one a storage could be created on: the system disk and the mounted
	// hot-state disk are not offered
	if got := names(avail); len(got) != 1 || got[0] != "vdb" {
		t.Fatalf("avail = %v", got)
	}
	blank := driveByName(t, avail, "vdb")
	if !blank.NeedFormat || blank.ChildrenNumber != 0 || len(blank.Children) != 0 || blank.Size != 8589934592 {
		t.Fatalf("blank disk = %+v", blank)
	}
	if blank.Children == nil {
		t.Fatal("children must be an empty list, not null: the UI iterates it")
	}
	if blank.Health != "true" || blank.Temperature != 0 {
		t.Fatalf("a disk that does not answer SMART must not look failing: %+v", blank)
	}
}

func TestDisksOnTheImageWithAPool(t *testing.T) {
	inv, _ := testInventory(t, "image-with-pool.json", baseConfig(""))
	disks, avail, err := inv.Disks(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(avail) != 0 {
		t.Fatalf("nothing is available once the only other disk is a mounted pool: %v", names(avail))
	}
	nvme := driveByName(t, disks, "nvme0n1")
	if nvme.DiskType != "NVMe" || nvme.Model != "System" || nvme.ChildrenNumber != 5 {
		t.Fatalf("system disk = %+v", nvme)
	}
	sda := driveByName(t, disks, "sda")
	if sda.DiskType != "HDD" || sda.Serial != "recasanix-data1" || !sda.Supported {
		t.Fatalf("pool disk = %+v", sda)
	}
}

func TestStorageHidesTheSystemDiskUnlessAsked(t *testing.T) {
	inv, _ := testInventory(t, "image-with-pool.json", baseConfig(""))
	list, err := inv.Storage(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].Path != "/dev/sda" {
		t.Fatalf("storage = %+v", list)
	}
}

func TestStorageOfThePool(t *testing.T) {
	fstab := writeFstab(t, "# /etc/fstab\n/dev/disk/by-label/recasanix-data /var/lib/recasanix/data btrfs noauto 0 2\n")
	inv, _ := testInventory(t, "image-with-pool.json", baseConfig(fstab))
	list, err := inv.Storage(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	v := list[0].Children[0]
	if v.MountPoint != "/DATA" {
		t.Fatalf("the pool must be presented at the data root, got %q", v.MountPoint)
	}
	if v.Label != "recasanix-data" || v.Type != "btrfs" || v.Path != "/dev/sda" || v.DriveName != "sda" {
		t.Fatalf("volume = %+v", v)
	}
	// sizes are decimal strings, as the UI has always received them
	if v.Size != "8589934592" || v.Avail != "8500000000" || v.Used != "89934592" {
		t.Fatalf("sizes = %q %q %q", v.Size, v.Avail, v.Used)
	}
	if v.PersistedIn != "fstab" {
		t.Fatalf("declared in fstab, reported as %q", v.PersistedIn)
	}
	if list[0].DiskName != "QEMU HARDDISK" {
		t.Fatalf("disk name = %q", list[0].DiskName)
	}
}

func TestStorageOfTheSystemDisk(t *testing.T) {
	inv, _ := testInventory(t, "image-with-pool.json", baseConfig(""))
	list, err := inv.Storage(context.Background(), true)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 2 {
		t.Fatalf("want the system disk and the pool, got %+v", list)
	}
	sys := list[0]
	if sys.DiskName != "System" {
		t.Fatalf("system disk name = %q", sys.DiskName)
	}
	// the root filesystem is there; the state filesystem (plumbing), the unmounted boot partition and
	// the empty partitions are not
	if len(sys.Children) != 1 {
		t.Fatalf("system volumes = %+v", sys.Children)
	}
	root := sys.Children[0]
	if root.MountPoint != "/" || root.Label != "recasanix-root-a" {
		t.Fatalf("a root also mounted at /nix/store must be presented at /, got %+v", root)
	}
	if root.PersistedIn != "none" {
		t.Fatalf("no fstab given, persisted_in = %q", root.PersistedIn)
	}
}

func TestStorageLabelsAnUnlabelledRootSystem(t *testing.T) {
	blocks := []byte(`{"blockdevices":[{"name":"sda","path":"/dev/sda","type":"disk","size":100,"children":[{"name":"sda1","path":"/dev/sda1","type":"part","size":100,"fstype":"ext4","mountpoints":["/"],"fssize":100,"fsavail":50,"fsused":50}]}]}`)
	run := newFakeRunner()
	run.outputs[lsblkCall] = blocks
	inv := newInventory(baseConfig(""), run, newSmartReader(run, time.Minute))
	list, err := inv.Storage(context.Background(), true)
	if err != nil {
		t.Fatal(err)
	}
	if list[0].Children[0].Label != "System" {
		t.Fatalf("label = %q", list[0].Children[0].Label)
	}
}

func TestBootAndSwapAreNotStorage(t *testing.T) {
	blocks := []byte(`{"blockdevices":[{"name":"sda","path":"/dev/sda","type":"disk","size":100,"children":[
	 {"name":"sda1","path":"/dev/sda1","type":"part","size":10,"fstype":"vfat","mountpoints":["/boot/efi"]},
	 {"name":"sda2","path":"/dev/sda2","type":"part","size":10,"fstype":"swap","mountpoints":["[SWAP]"]},
	 {"name":"sda3","path":"/dev/sda3","type":"part","size":80,"fstype":"ext4","mountpoints":["/"]}]}]}`)
	run := newFakeRunner()
	run.outputs[lsblkCall] = blocks
	inv := newInventory(baseConfig(""), run, newSmartReader(run, time.Minute))
	list, _ := inv.Storage(context.Background(), true)
	if len(list) != 1 || len(list[0].Children) != 1 || list[0].Children[0].DriveName != "sda3" {
		t.Fatalf("storage = %+v", list)
	}
}

func TestAMirrorIsListedOnce(t *testing.T) {
	inv, _ := testInventory(t, "mirror-pool.json", baseConfig(""))
	list, err := inv.Storage(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	total := 0
	for _, d := range list {
		total += len(d.Children)
	}
	if total != 1 {
		t.Fatalf("a two-disk btrfs is one storage, listed %d times: %+v", total, list)
	}
	// both members are still disks
	disks, avail, _ := inv.Disks(context.Background())
	if len(disks) != 2 || len(avail) != 0 {
		t.Fatalf("disks=%v avail=%v", names(disks), names(avail))
	}
}

func TestEmptyResultsAreListsNotNull(t *testing.T) {
	run := newFakeRunner()
	run.outputs[lsblkCall] = []byte(`{"blockdevices":[]}`)
	inv := newInventory(baseConfig(""), run, newSmartReader(run, time.Minute))
	disks, avail, _ := inv.Disks(context.Background())
	list, _ := inv.Storage(context.Background(), true)
	if disks == nil || avail == nil || list == nil {
		t.Fatal("the UI iterates these: they must be empty lists, never null")
	}
}

func TestUnsupportedFilesystemsAreFlagged(t *testing.T) {
	blocks := []byte(`{"blockdevices":[{"name":"sdb","path":"/dev/sdb","type":"disk","size":100,"children":[{"name":"sdb1","path":"/dev/sdb1","type":"part","size":100,"fstype":"LVM2_member"}]}]}`)
	run := newFakeRunner()
	run.outputs[lsblkCall] = blocks
	inv := newInventory(baseConfig(""), run, newSmartReader(run, time.Minute))
	disks, avail, _ := inv.Disks(context.Background())
	if disks[0].Supported || disks[0].Children[0].Supported {
		t.Fatalf("a member of an LVM stack must not be shown as formattable: %+v", disks[0])
	}
	if len(avail) != 0 {
		t.Fatalf("a disk with an existing partition is not blank and must not be offered for creating storage: %+v", avail)
	}
}

func TestLsblkFailureIsAnError(t *testing.T) {
	run := newFakeRunner()
	run.errs[lsblkCall] = os.ErrNotExist
	inv := newInventory(baseConfig(""), run, newSmartReader(run, time.Minute))
	if _, _, err := inv.Disks(context.Background()); err == nil {
		t.Fatal("expected an error")
	}
	if _, err := inv.Storage(context.Background(), true); err == nil {
		t.Fatal("expected an error")
	}
}

// A single-disk machine keeps its pool on a partition of the system disk (the image's blank
// `recasanix-data` partition). It must be listed — under the System disk, next to the root — but only when
// the system disk is asked for, and the hot-state partition next to it must still not be.
func TestAPoolOnAPartitionOfTheSystemDisk(t *testing.T) {
	blocks := []byte(`{"blockdevices":[{"name":"mmcblk0","path":"/dev/mmcblk0","type":"disk","size":32000000000,"children":[
	 {"name":"mmcblk0p1","path":"/dev/mmcblk0p1","type":"part","size":500000000,"fstype":"vfat","label":"recasa-esp","mountpoints":[null]},
	 {"name":"mmcblk0p2","path":"/dev/mmcblk0p2","type":"part","size":8000000000,"fstype":"ext4","label":"recasanix-root-a","uuid":"r","mountpoints":["/nix/store","/"],"fssize":7900000000,"fsavail":5000000000,"fsused":2900000000},
	 {"name":"mmcblk0p4","path":"/dev/mmcblk0p4","type":"part","size":4000000000,"fstype":"ext4","label":"recasanix-state","uuid":"s","mountpoints":["/var/lib/recasanix/state"]},
	 {"name":"mmcblk0p5","path":"/dev/mmcblk0p5","type":"part","size":12000000000,"fstype":"btrfs","label":"recasanix-data","uuid":"p","mountpoints":["/DATA","/var/lib/recasanix/data"],"fssize":12000000000,"fsavail":11900000000,"fsused":100000000}]}]}`)
	run := newFakeRunner()
	run.outputs[lsblkCall] = blocks
	inv := newInventory(baseConfig(""), run, newSmartReader(run, time.Minute))

	shown, err := inv.Storage(context.Background(), true)
	if err != nil {
		t.Fatal(err)
	}
	if len(shown) != 1 || shown[0].DiskName != "System" || len(shown[0].Children) != 2 {
		t.Fatalf("storage = %+v", shown)
	}
	labels := []string{shown[0].Children[0].Label, shown[0].Children[1].Label}
	if labels[0] != "recasanix-root-a" || labels[1] != "recasanix-data" || shown[0].Children[1].MountPoint != "/DATA" {
		t.Fatalf("volumes = %v (the state partition must not be among them)", labels)
	}

	hidden, _ := inv.Storage(context.Background(), false)
	if len(hidden) != 0 {
		t.Fatalf("without ?system=show the system disk is left out: %+v", hidden)
	}
	// and the system disk is never offered for a new storage, whatever its free space
	_, avail, _ := inv.Disks(context.Background())
	if len(avail) != 0 {
		t.Fatalf("avail = %v", names(avail))
	}
}

func TestTooSmallDisksAreNotOffered(t *testing.T) {
	blocks := []byte(`{"blockdevices":[
	 {"name":"sda","path":"/dev/sda","type":"disk","size":104857600,"fstype":null,"mountpoints":[null]},
	 {"name":"sdb","path":"/dev/sdb","type":"disk","size":1073741824,"fstype":null,"mountpoints":[null]}
	]}`)
	run := newFakeRunner()
	run.outputs[lsblkCall] = blocks
	inv := newInventory(baseConfig(""), run, newSmartReader(run, time.Minute))
	_, avail, err := inv.Disks(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got := names(avail); len(got) != 1 || got[0] != "sdb" {
		t.Fatalf("avail = %v, want only the disk at or above the minimum size", got)
	}
}
