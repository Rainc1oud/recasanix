package main

import (
	"bufio"
	"context"
	"os"
	"path"
	"sort"
	"strconv"
	"strings"
)

// Config is the part of the appliance's layout this service has to know about.
type Config struct {
	// DataRoot is the mount point the UI and the apps use for the data pool ("/DATA"). When a volume
	// is mounted there, that is the mount point reported for it.
	DataRoot string
	// HiddenMounts are volumes that are system plumbing, not storage a user could put apps on: the
	// hot-state filesystem, above all.
	HiddenMounts []string
	// FstabPath is read to tell whether a mount is persisted by the operating system's configuration.
	FstabPath string
	// PoolLabel is the filesystem label of the data pool (recasanix.storage.poolLabel).
	PoolLabel string
	// PoolMountPoint is where the pool is mounted (recasanix.storage.mountPoint), not to be confused with
	// DataRoot: DataRoot is where the pool's DATA subdirectory is bind-mounted for the UI and apps.
	PoolMountPoint string
	// MinDiskSize is the smallest disk, in bytes, offered for creating storage.
	MinDiskSize uint64
}

// Inventory answers what disks and volumes the machine has. It only reads.
type Inventory struct {
	cfg   Config
	run   Runner
	smart *smartReader
}

func newInventory(cfg Config, run Runner, smart *smartReader) *Inventory {
	return &Inventory{cfg: cfg, run: run, smart: smart}
}

// --- the shapes the UI was written against (CasaOS-LocalStorage's v1 API) ---------------------

// Drive is one physical disk in /v1/disks.
type Drive struct {
	Name           string      `json:"name"`
	Size           uint64      `json:"size"`
	Model          string      `json:"model"`
	Health         string      `json:"health"`
	Temperature    int         `json:"temperature"`
	DiskType       string      `json:"disk_type"`
	NeedFormat     bool        `json:"need_format"`
	Serial         string      `json:"serial"`
	Path           string      `json:"path"`
	ChildrenNumber int         `json:"children_number"`
	Children       []DiskChild `json:"children"`
	Supported      bool        `json:"supported"`
}

type DiskChild struct {
	Name      string `json:"name"`
	Size      uint64 `json:"size"`
	Format    string `json:"format"`
	Supported bool   `json:"supported"`
}

// StorageDisk is one disk with the volumes on it, in /v1/storage. Note the volume sizes are strings:
// that is what the UI's contract has always been.
type StorageDisk struct {
	DiskName string   `json:"disk_name"`
	Size     uint64   `json:"size"`
	Path     string   `json:"path"`
	Type     string   `json:"type"`
	Children []Volume `json:"children"`
}

type Volume struct {
	UUID        string `json:"uuid"`
	MountPoint  string `json:"mount_point"`
	Size        string `json:"size"`
	Avail       string `json:"avail"`
	Used        string `json:"used"`
	Type        string `json:"type"`
	Path        string `json:"path"`
	DriveName   string `json:"drive_name"`
	Label       string `json:"label"`
	PersistedIn string `json:"persisted_in"` // "fstab" (declared by the OS configuration) or "none"
}

// physicalDisks keeps what a user would call a disk: not loop, RAM or network block devices, and not
// an empty card reader.
func physicalDisks(blocks []Block) []Block {
	var disks []Block
	for _, b := range blocks {
		if b.Type != "disk" || b.Size == 0 || !strings.HasPrefix(b.Path, "/dev/") {
			continue
		}
		if hasAnyPrefix(b.Name, "zram", "ram", "nbd", "loop") {
			continue
		}
		disks = append(disks, b)
	}
	return disks
}

func hasAnyPrefix(s string, prefixes ...string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

func walk(b Block, fn func(Block)) {
	fn(b)
	for _, c := range b.Children {
		walk(c, fn)
	}
}

// isSystemDisk is the disk that carries the running system: the one with "/" somewhere on it.
// mountedFilesystems is the set of filesystem UUIDs that are mounted somewhere. A multi-device btrfs
// (a mirror) is mounted once, and lsblk reports the mount point on only one member: the others are
// recognisable only by sharing the filesystem UUID.
func mountedFilesystems(disks []Block) map[string]bool {
	set := map[string]bool{}
	for _, d := range disks {
		walk(d, func(x Block) {
			if len(x.Mounts) > 0 && x.UUID != "" {
				set[x.UUID] = true
			}
		})
	}
	return set
}

// inUse: something on the disk is mounted, or is a member of a filesystem that is.
func inUse(d Block, mounted map[string]bool) bool {
	used := false
	walk(d, func(x Block) {
		if len(x.Mounts) > 0 || (x.UUID != "" && mounted[x.UUID]) {
			used = true
		}
	})
	return used
}

func isSystemDisk(b Block) bool {
	system := false
	walk(b, func(x Block) {
		for _, m := range x.Mounts {
			if m == "/" {
				system = true
			}
		}
	})
	return system
}

func diskType(b Block) string {
	switch {
	case b.Transport == "usb":
		return "USB"
	case strings.HasPrefix(b.Name, "mmcblk"):
		return "MMC"
	case b.Transport == "nvme" || strings.HasPrefix(b.Name, "nvme"):
		return "NVMe"
	case b.Rotational:
		return "HDD"
	default:
		return "SSD"
	}
}

// supportedFS: filesystems the appliance can work with, plus "blank" (no filesystem at all). A member
// of some other storage stack (LVM, RAID, LUKS, ZFS, swap) is not something to offer for formatting.
func supportedFS(fstype string) bool {
	switch fstype {
	case "", "ext2", "ext3", "ext4", "btrfs", "xfs", "f2fs", "vfat", "exfat", "ntfs":
		return true
	}
	return false
}

// health renders SMART for the UI. The UI only tests the string for truthiness, so a disk that
// SMART reports as failing is the empty string (it shows "Damage"), and everything else — including
// "SMART does not answer", which virtual disks do — is non-empty. That limitation belongs to the UI.
func health(i smartInfo) string {
	if i.Known && !i.Passed {
		return ""
	}
	return "true"
}

// Disks returns every physical disk and, separately, those a new storage could be created on.
func (inv *Inventory) Disks(ctx context.Context) (disks, avail []Drive, err error) {
	blocks, err := listBlocks(ctx, inv.run)
	if err != nil {
		return nil, nil, err
	}
	disks, avail = []Drive{}, []Drive{}
	physical := physicalDisks(blocks)
	mounted := mountedFilesystems(physical)
	for _, d := range physical {
		system := isSystemDisk(d)
		info := inv.smart.Info(ctx, d.Path)

		drive := Drive{
			Name:           d.Name,
			Size:           d.Size,
			Model:          d.Model,
			Health:         health(info),
			Temperature:    info.Temperature,
			DiskType:       diskType(d),
			NeedFormat:     len(d.Children) == 0 && d.FSType == "",
			Serial:         d.Serial,
			Path:           d.Path,
			ChildrenNumber: len(d.Children),
			Children:       []DiskChild{},
			Supported:      true,
		}
		for _, c := range d.Children {
			s := supportedFS(c.FSType)
			drive.Children = append(drive.Children, DiskChild{Name: c.Name, Size: c.Size, Format: c.FSType, Supported: s})
			if !s {
				drive.Supported = false
			}
		}
		if len(d.Children) == 0 && !supportedFS(d.FSType) {
			drive.Supported = false
		}

		if system {
			// The UI keys the label of the system disk on this.
			drive.Model = "System"
			drive.NeedFormat = false
			disks = append(disks, drive)
			continue
		}
		// Available for a new storage: blank (no partition table, no filesystem — this is what "Create
		// Storage" formats directly, no partitioning), not in use, and not so small it is unlikely to be
		// a real data disk.
		if !inUse(d, mounted) && drive.NeedFormat && d.Size >= inv.cfg.MinDiskSize {
			avail = append(avail, drive)
		}
		disks = append(disks, drive)
	}
	return disks, avail, nil
}

// Storage returns the mounted volumes, grouped by disk. The system disk only appears when asked for
// (`?system=show`), as in the original.
func (inv *Inventory) Storage(ctx context.Context, showSystem bool) ([]StorageDisk, error) {
	blocks, err := listBlocks(ctx, inv.run)
	if err != nil {
		return nil, err
	}
	fstab := inv.fstabMounts()
	seen := map[string]bool{} // a multi-device btrfs shows up on every member disk: list it once
	out := []StorageDisk{}

	for _, d := range physicalDisks(blocks) {
		system := isSystemDisk(d)
		if system && !showSystem {
			continue
		}

		candidates := d.Children
		if len(candidates) == 0 {
			candidates = []Block{d} // a whole disk used as one filesystem
		}
		sd := StorageDisk{DiskName: d.Model, Size: d.Size, Path: d.Path, Type: d.Transport, Children: []Volume{}}
		if system {
			sd.DiskName = "System"
		}
		if sd.DiskName == "" {
			sd.DiskName = d.Name
		}

		for _, v := range candidates {
			if !inv.isStorage(v) {
				continue
			}
			if v.UUID != "" && seen[v.UUID] {
				continue
			}
			seen[v.UUID] = true
			sd.Children = append(sd.Children, inv.volume(v, fstab))
		}
		if len(sd.Children) > 0 {
			out = append(out, sd)
		}
	}
	return out, nil
}

// isStorage: mounted somewhere a user could care about. Not the boot partition, not swap, and not the
// hot-state filesystem or anything else the configuration marks as plumbing.
func (inv *Inventory) isStorage(v Block) bool {
	if len(v.Mounts) == 0 || v.FSType == "swap" {
		return false
	}
	for _, m := range v.Mounts {
		if m == "/boot" || strings.HasPrefix(m, "/boot/") {
			return false
		}
		for _, hidden := range inv.cfg.HiddenMounts {
			if m == hidden {
				return false
			}
		}
	}
	return true
}

func (inv *Inventory) volume(v Block, fstab map[string]bool) Volume {
	mount := inv.chooseMount(v.Mounts)
	label := v.Label
	if label == "" {
		if mount == "/" {
			label = "System"
		} else {
			label = path.Base(mount)
		}
	}
	size := v.FSSize
	if size == 0 {
		size = v.Size
	}
	persisted := "none"
	for _, m := range v.Mounts {
		if fstab[m] {
			persisted = "fstab"
		}
	}
	return Volume{
		UUID:        v.UUID,
		MountPoint:  mount,
		Size:        strconv.FormatUint(size, 10),
		Avail:       strconv.FormatUint(v.FSAvail, 10),
		Used:        strconv.FormatUint(v.FSUsed, 10),
		Type:        v.FSType,
		Path:        v.Path,
		DriveName:   v.Name,
		Label:       label,
		PersistedIn: persisted,
	}
}

// chooseMount picks the one mount point to present when a volume is mounted several times (bind
// mounts, /nix/store on a NixOS root): the data root if it is there, otherwise the shortest path.
func (inv *Inventory) chooseMount(mounts []string) string {
	for _, m := range mounts {
		if m == inv.cfg.DataRoot {
			return m
		}
	}
	sorted := append([]string(nil), mounts...)
	sort.Slice(sorted, func(i, j int) bool {
		if len(sorted[i]) != len(sorted[j]) {
			return len(sorted[i]) < len(sorted[j])
		}
		return sorted[i] < sorted[j]
	})
	return sorted[0]
}

// fstabMounts is the set of mount points the operating system's configuration declares. A missing or
// unreadable file just means nothing is reported as persisted.
func (inv *Inventory) fstabMounts() map[string]bool {
	set := map[string]bool{}
	if inv.cfg.FstabPath == "" {
		return set
	}
	f, err := os.Open(inv.cfg.FstabPath)
	if err != nil {
		return set
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if fields := strings.Fields(line); len(fields) >= 2 {
			set[strings.ReplaceAll(fields[1], `\040`, " ")] = true
		}
	}
	return set
}
