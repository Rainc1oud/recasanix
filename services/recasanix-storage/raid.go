package main

import (
	"context"
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// RAIDArray is one entry of GET /v1/disks/raid: CasaOS-LocalStorage's shape for a Linux md array,
// filled here from a multi-device btrfs (the appliance's pool: JBOD or a mirror). The UI attaches it
// to the storage listed under the same disk path.
type RAIDArray struct {
	Name  string `json:"name"`  // the filesystem label, else the start of its UUID
	Path  string `json:"path"`  // the disk /v1/storage lists the volume under
	Level string `json:"level"` // the data profile: single, raid1, raid1c3, raid10…; "" when not mounted
	// State: ok, degraded (a member missing or failed), rebuilding (device replace), checking (scrub),
	// reshaping (balance, device removal, two data profiles), inactive (not mounted, a member missing).
	State   string `json:"state"`
	Disks   int    `json:"disks"`
	Missing int    `json:"missing"`
	// ComponentSize: the smallest member, in bytes; a disk to add would need at least that.
	ComponentSize int64 `json:"component_size"`
	// Action: idle, recover, check, reshape. Progress in percent, Remaining in seconds; -1 = unknown.
	Action    string       `json:"action"`
	Progress  float64      `json:"progress"`
	Remaining int64        `json:"remaining"`
	Members   []RAIDMember `json:"members"`
}

// RAIDMember is a device of the filesystem.
type RAIDMember struct {
	Name  string `json:"name"`  // vdb, sdb1; "devid N" when the kernel has no device for it
	Disk  string `json:"disk"`  // the disk it is on
	State string `json:"state"` // active, rebuilding (replace target), faulty (missing or gone)
	// Errors: the kernel's error counters for the device (write, read, flush, corruption,
	// generation), summed. Not in LocalStorage's shape; the UI ignores it.
	Errors uint64 `json:"errors"`
}

// btrfsKernel is what only the kernel (an ioctl on a mounted btrfs, raid_linux.go) or the device
// itself answers.
type btrfsKernel interface {
	// Devices: how many devices the filesystem on dev was made of (its superblock).
	Devices(dev string) (uint64, error)
	// DevInfo: the device path ("" when missing) and size of a member.
	DevInfo(mount string, devid uint64) (path string, size uint64, err error)
	// ScrubProgress: whether a scrub runs on the member, and the bytes it has read so far.
	ScrubProgress(mount string, devid uint64) (running bool, scrubbed uint64, err error)
	// ReplaceProgress: whether a device replace runs, and its progress in permille.
	ReplaceProgress(mount string) (running bool, permille uint64, err error)
}

// btrfsFS is one btrfs filesystem as lsblk shows it: its members and where it is mounted.
type btrfsFS struct {
	uuid, label string
	members     []Block
	mounts      []string
}

// RAID lists the btrfs filesystems with more than one device: mounted ones from the kernel's view
// (sysfs, ioctls), unmounted ones only when a member is missing (they cannot mount as they are).
func (inv *Inventory) RAID(ctx context.Context) ([]RAIDArray, error) {
	blocks, err := listBlocks(ctx, inv.run)
	if err != nil {
		return nil, err
	}
	physical := physicalDisks(blocks)

	var order []string
	filesystems := map[string]*btrfsFS{}
	for _, d := range physical {
		walk(d, func(b Block) {
			if b.FSType != "btrfs" || b.UUID == "" {
				return
			}
			fs := filesystems[b.UUID]
			if fs == nil {
				fs = &btrfsFS{uuid: b.UUID, label: b.Label}
				filesystems[b.UUID] = fs
				order = append(order, b.UUID)
			}
			fs.members = append(fs.members, b)
			fs.mounts = append(fs.mounts, b.Mounts...)
		})
	}

	listedUnder := inv.storageDisks(physical)
	arrays := []RAIDArray{}
	for _, uuid := range order {
		fs := filesystems[uuid]
		var array *RAIDArray
		if len(fs.mounts) > 0 {
			array = inv.mountedArray(fs)
		} else {
			array = inv.unmountedArray(fs)
		}
		if array == nil {
			continue
		}
		array.Name = fs.label
		if array.Name == "" {
			array.Name = uuid[:min(8, len(uuid))]
		}
		array.Path = listedUnder[uuid]
		if array.Path == "" {
			array.Path = fs.members[0].Path
		}
		arrays = append(arrays, *array)
	}
	return arrays, nil
}

// storageDisks: for each filesystem UUID, the disk path Storage lists it under (the UI matches an
// array to a storage by it).
func (inv *Inventory) storageDisks(physical []Block) map[string]string {
	under := map[string]string{}
	for _, d := range physical {
		candidates := d.Children
		if len(candidates) == 0 {
			candidates = []Block{d}
		}
		for _, v := range candidates {
			if v.UUID != "" && under[v.UUID] == "" && inv.isStorage(v) {
				under[v.UUID] = d.Path
			}
		}
	}
	return under
}

// btrfsProfiles: the block-group profiles under allocation/<kind>.
var btrfsProfiles = []string{"single", "dup", "raid0", "raid1", "raid1c3", "raid1c4", "raid10", "raid5", "raid6"}

func (inv *Inventory) mountedArray(fs *btrfsFS) *RAIDArray {
	dir := filepath.Join(inv.sys, "fs", "btrfs", fs.uuid)
	entries, err := os.ReadDir(filepath.Join(dir, "devinfo"))
	if err != nil {
		return nil
	}
	mount := inv.chooseMount(fs.mounts)
	array := &RAIDArray{Action: "idle", Progress: -1, Remaining: -1, Members: []RAIDMember{}}

	var devids []uint64
	for _, e := range entries {
		if id, err := strconv.ParseUint(e.Name(), 10, 64); err == nil {
			devids = append(devids, id)
		}
	}
	sort.Slice(devids, func(i, j int) bool { return devids[i] < devids[j] })

	var scrubbed uint64
	scrubbing := false
	for _, id := range devids {
		info := filepath.Join(dir, "devinfo", strconv.FormatUint(id, 10))
		member := RAIDMember{Name: "devid " + strconv.FormatUint(id, 10), State: "active", Errors: errorCount(readSys(info, "error_stats"))}
		path, size, err := inv.btrfs.DevInfo(mount, id)
		present := false
		if err == nil && path != "" {
			member.Name = filepath.Base(path)
			// a device unplugged while mounted keeps its devinfo, missing = 0: only the block device is gone
			_, statErr := os.Stat(filepath.Join(inv.sys, "class", "block", member.Name))
			present = statErr == nil
		}
		if present {
			member.Disk = diskOf(inv.sys, member.Name)
		}
		replaceTarget := readSys(info, "replace_target") == "1"
		switch {
		case replaceTarget:
			member.State = "rebuilding"
		case readSys(info, "missing") == "1" || !present:
			member.State = "faulty"
			array.Missing++
		}
		if !replaceTarget {
			array.Disks++
			if member.State == "active" && (array.ComponentSize == 0 || int64(size) < array.ComponentSize) {
				array.ComponentSize = int64(size)
			}
		}
		if present {
			if running, n, err := inv.btrfs.ScrubProgress(mount, id); err == nil && running {
				scrubbing = true
				scrubbed += n
			}
		}
		array.Members = append(array.Members, member)
	}
	if array.Disks < 2 {
		return nil // one device: no array, as an md-less disk has none
	}

	profiles := map[string]uint64{}
	for _, p := range btrfsProfiles {
		if total, err := strconv.ParseUint(readSys(filepath.Join(dir, "allocation", "data", p), "total_bytes"), 10, 64); err == nil {
			profiles[p] = total
		}
	}
	for p, total := range profiles {
		if array.Level == "" || total > profiles[array.Level] || (total == profiles[array.Level] && p < array.Level) {
			array.Level = p
		}
	}

	switch readSys(dir, "exclusive_operation") {
	case "device replace":
		array.Action = "recover"
		if running, permille, err := inv.btrfs.ReplaceProgress(mount); err == nil && running {
			array.Progress = float64(permille) / 10
		}
	case "balance", "balance paused", "device remove":
		array.Action = "reshape"
	default:
		switch {
		case len(profiles) > 1: // an interrupted conversion leaves two data profiles
			array.Action = "reshape"
		case scrubbing:
			array.Action = "check"
			var used uint64
			for _, kind := range []string{"data", "metadata", "system"} {
				n, _ := strconv.ParseUint(readSys(filepath.Join(dir, "allocation", kind), "disk_used"), 10, 64)
				used += n
			}
			if used > 0 {
				array.Progress = min(100, float64(scrubbed)*100/float64(used))
			}
		}
	}

	switch {
	case array.Action == "recover":
		array.State = "rebuilding"
	case array.Missing > 0:
		array.State = "degraded"
	case array.Action == "check":
		array.State = "checking"
	case array.Action == "reshape":
		array.State = "reshaping"
	default:
		array.State = "ok"
	}
	return array
}

// unmountedArray: a multi-device btrfs that is not mounted is only reported when a member is missing —
// it cannot mount without `degraded` then. Its profile is unknown without mounting it.
func (inv *Inventory) unmountedArray(fs *btrfsFS) *RAIDArray {
	total, err := inv.btrfs.Devices(fs.members[0].Path)
	if err != nil || total < 2 || total <= uint64(len(fs.members)) {
		return nil
	}
	array := &RAIDArray{
		State: "inactive", Action: "idle", Progress: -1, Remaining: -1,
		Disks: int(total), Missing: int(total) - len(fs.members), Members: []RAIDMember{},
	}
	for _, m := range fs.members {
		array.Members = append(array.Members, RAIDMember{Name: m.Name, Disk: diskOf(inv.sys, m.Name), State: "active"})
		if array.ComponentSize == 0 || int64(m.Size) < array.ComponentSize {
			array.ComponentSize = int64(m.Size)
		}
	}
	return array
}

// errorCount sums the counters of devinfo/<id>/error_stats ("write_errs 0\nread_errs 0\n…").
func errorCount(stats string) uint64 {
	var n uint64
	for _, line := range strings.Split(stats, "\n") {
		if f := strings.Fields(line); len(f) == 2 {
			v, _ := strconv.ParseUint(f[1], 10, 64)
			n += v
		}
	}
	return n
}

// diskOf is the disk a block device is on: its parent for a partition, itself otherwise.
func diskOf(sys, name string) string {
	real, err := filepath.EvalSymlinks(filepath.Join(sys, "class", "block", name))
	if err != nil {
		return name
	}
	if _, err := os.Stat(filepath.Join(real, "partition")); err == nil {
		return filepath.Base(filepath.Dir(real))
	}
	return name
}

func readSys(dir, name string) string {
	data, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// The primary btrfs superblock: 64 KiB into the device; magic at 0x40, num_devices at 0x88.
const (
	superblockOffset = 0x10000
	superblockMagic  = "_BHRfS_M"
)

var errNotBtrfs = errors.New("no btrfs superblock")

// superblockDevices reads how many devices the filesystem on dev was made of.
func superblockDevices(dev string) (uint64, error) {
	f, err := os.Open(dev)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	buf := make([]byte, 0x90)
	if _, err := f.ReadAt(buf, superblockOffset); err != nil {
		return 0, err
	}
	if string(buf[0x40:0x48]) != superblockMagic {
		return 0, errNotBtrfs
	}
	return binary.LittleEndian.Uint64(buf[0x88:0x90]), nil
}
