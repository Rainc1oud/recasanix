package main

import (
	"context"
	"slices"
	"strings"
)

// The storage layer's view (docs/storage-layer.md): the appliance's one pool (the filesystem labelled
// Config.PoolLabel, decision C1) and every drive with its role. Backend-neutral words; the backend
// (btrfs, md) is named, not exposed in the verbs.

// Pool is the appliance's pool.
type Pool struct {
	Name    string `json:"name"`
	Backend string `json:"backend"` // btrfs, md
	Layout  Layout `json:"layout"`
	// LayoutKnown is false when the pool's profile is none of the layouts offered (made by hand:
	// raid0, raid10…) or cannot be read (not mounted).
	LayoutKnown bool   `json:"layout_known"`
	Profile     string `json:"profile"` // the backend's word: single, raid1, raid5…
	Description string `json:"description"`
	State       string `json:"state"` // ok, degraded, rebuilding, checking, resyncing, reshaping, inactive
	Mounted     bool   `json:"mounted"`
	// Tolerates: disks the pool can lose now without losing data.
	Tolerates int          `json:"tolerates"`
	Disks     int          `json:"disks"`
	Missing   int          `json:"missing"`
	Size      uint64       `json:"size"`
	Used      uint64       `json:"used"`
	Avail     uint64       `json:"avail"`
	Action    string       `json:"action"`   // idle, recover, check, reshape, resync
	Progress  float64      `json:"progress"` // percent; -1 unknown
	Members   []PoolMember `json:"members"`
	Verbs     []string     `json:"verbs"` // what can be asked of it now
	// Problem: what is wrong beyond the state, in a person's words ("" when nothing)
	Problem string `json:"problem,omitempty"`

	array   *RAIDArray // nil: a single-device btrfs
	device  string     // md: /dev/mdN
	mount   string
	members []Block // btrfs single device: its block
}

// PoolMember is a disk (or a missing one) of the pool.
type PoolMember struct {
	Name   string `json:"name"`  // vdb; "devid 2" for a btrfs member the kernel has no device for
	Disk   string `json:"disk"`  // the drive it is on, "" when gone
	State  string `json:"state"` // active, rebuilding, spare, faulty
	Size   uint64 `json:"size"`
	Errors uint64 `json:"errors"`

	devid uint64
}

// StorageDrive is a physical disk in the storage layer's view.
type StorageDrive struct {
	Name        string `json:"name"`
	Path        string `json:"path"`
	Model       string `json:"model"`
	Serial      string `json:"serial"`
	Type        string `json:"type"` // HDD, SSD, NVMe, USB, MMC
	Size        uint64 `json:"size"`
	SmartStatus string `json:"smart_status"`
	Temperature int    `json:"temperature"`
	// Role: system (carries the OS), member (of the pool), free (blank, usable), small (blank, under
	// the minimum size), foreign (holds something else, not in use: can be wiped), busy (in use
	// elsewhere: nothing offered).
	Role    string   `json:"role"`
	Pool    string   `json:"pool,omitempty"`
	Content string   `json:"content,omitempty"` // what is on it: btrfs, ext4, linux_raid_member, partitions…
	Verbs   []string `json:"verbs"`

	block Block
}

// storageView is one fresh look at the machine: what the API shows and the planner decides on.
type storageView struct {
	pool   *Pool // nil: no pool
	drives []StorageDrive
}

func (v *storageView) drive(name string) *StorageDrive {
	for i := range v.drives {
		if v.drives[i].Name == name {
			return &v.drives[i]
		}
	}
	return nil
}

func (v *storageView) free() []StorageDrive {
	var free []StorageDrive
	for _, d := range v.drives {
		if d.Role == "free" {
			free = append(free, d)
		}
	}
	return free
}

func (inv *Inventory) view(ctx context.Context) (*storageView, error) {
	blocks, err := listBlocks(ctx, inv.run)
	if err != nil {
		return nil, err
	}
	arrays, err := inv.RAID(ctx)
	if err != nil {
		return nil, err
	}
	physical := physicalDisks(blocks)
	v := &storageView{pool: inv.findPool(physical, arrays)}

	mounted := mountedFilesystems(physical)
	for _, d := range physical {
		info := inv.smart.Info(ctx, d.Path)
		drive := StorageDrive{
			Name: d.Name, Path: d.Path, Model: d.Model, Serial: d.Serial, Type: diskType(d), Size: d.Size,
			SmartStatus: smartStatus(info), Temperature: info.Temperature, Content: content(d), Verbs: []string{},
			block: d,
		}
		switch {
		case isSystemDisk(d):
			drive.Role = "system"
		case v.pool != nil && inv.isPoolMember(d, v.pool):
			drive.Role, drive.Pool = "member", v.pool.Name
		case inUse(d, mounted):
			drive.Role = "busy"
		case drive.Content == "":
			drive.Role = "free"
			if d.Size < inv.cfg.MinDiskSize {
				drive.Role = "small"
			}
		default:
			drive.Role = "foreign"
		}
		v.drives = append(v.drives, drive)
	}
	v.verbs()
	return v, nil
}

// content is what is on a disk: its filesystem or signature, "partitions", or "" for blank.
func content(d Block) string {
	switch {
	case d.FSType != "":
		return d.FSType
	case len(d.Children) > 0:
		return "partitions"
	}
	return ""
}

// findPool is the filesystem labelled PoolLabel: a btrfs on disks, or a btrfs on an md array (parity
// layouts); also an md array named for the pool that does not run (its filesystem is then not seen).
func (inv *Inventory) findPool(physical []Block, arrays []RAIDArray) *Pool {
	label := inv.cfg.PoolLabel
	// the pool's filesystem: lsblk shows a multi-device btrfs on every member, mounted on one only
	var fs *Block
	for _, d := range physical {
		walk(d, func(b Block) {
			if b.Label == label && b.FSType == "btrfs" && (fs == nil || (len(fs.Mounts) == 0 && len(b.Mounts) > 0)) {
				found := b
				fs = &found
			}
		})
	}
	p := &Pool{Name: label, Progress: -1, Action: "idle", Members: []PoolMember{}, Verbs: []string{}}
	switch {
	case fs != nil && (strings.HasPrefix(fs.Type, "raid") || fs.Type == "md"):
		p.Backend, p.device = "md", fs.Path
		for i := range arrays {
			if arrays[i].backend == "md" && (arrays[i].device == fs.Path || arrays[i].uuid == fs.UUID) {
				p.array = &arrays[i]
				p.device = arrays[i].device
			}
		}
	case fs != nil:
		p.Backend = "btrfs"
		for i := range arrays {
			if arrays[i].backend == "btrfs" && arrays[i].uuid == fs.UUID {
				p.array = &arrays[i]
			}
		}
		if p.array == nil { // one device
			for _, d := range physical {
				walk(d, func(b Block) {
					if b.UUID == fs.UUID {
						p.members = append(p.members, b)
					}
				})
			}
		}
	default:
		// an md array named for the pool, not running: no filesystem to see
		for i := range arrays {
			a := &arrays[i]
			if a.backend == "md" && a.State == "inactive" && inv.mdNamedForPool(physical, a) {
				p.Backend, p.array, p.device = "md", a, a.device
			}
		}
		if p.array == nil {
			return nil
		}
	}

	if fs != nil {
		p.Mounted = len(fs.Mounts) > 0
		if p.Mounted {
			p.mount = inv.cfg.PoolMountPoint
			if !slices.Contains(fs.Mounts, p.mount) {
				p.mount = inv.chooseMount(fs.Mounts)
			}
			p.Size, p.Used, p.Avail = max(fs.FSSize, fs.Size), fs.FSUsed, fs.FSAvail
		}
	}
	if a := p.array; a != nil {
		p.State, p.Disks, p.Missing, p.Action, p.Progress, p.Profile = a.State, a.Disks, a.Missing, a.Action, a.Progress, a.Level
		for _, m := range a.Members {
			p.Members = append(p.Members, PoolMember{Name: m.Name, Disk: m.Disk, State: m.State, Size: m.size, Errors: m.Errors, devid: m.devid})
		}
		if a.backend == "md" {
			p.Profile = a.Level
		}
	} else {
		p.State, p.Disks = "ok", len(p.members)
		p.Profile = "single"
		for _, b := range p.members {
			p.Members = append(p.Members, PoolMember{Name: b.Name, Disk: diskOf(inv.sys, b.Name), State: "active", Size: b.Size, devid: 1})
		}
	}
	if p.Backend == "btrfs" && p.Mounted && p.array == nil {
		p.Profile = inv.dataProfile(fs.UUID)
	}
	p.Layout, p.LayoutKnown = layoutOfProfile(p.Profile)
	if p.LayoutKnown {
		p.Description = p.Layout.String()
		p.Tolerates = max(0, p.Layout.Tolerates()-p.Missing)
	}
	if p.array != nil && p.array.mixed && p.Action == "idle" {
		p.Tolerates = 0
		p.Problem = "Part of the data is not in the pool's layout (written while a disk was missing, or a layout change that stopped): restore the protection."
		if p.State == "ok" {
			p.State = "degraded"
		}
	}
	return p
}

// dataProfile is the main data profile of a mounted btrfs (sysfs), "single" when unreadable.
func (inv *Inventory) dataProfile(uuid string) string {
	best, bestTotal := "single", uint64(0)
	for _, p := range btrfsProfiles {
		total := uint64(atoi(readSys(inv.sys+"/fs/btrfs/"+uuid+"/allocation/data/"+p, "total_bytes")))
		if total > bestTotal {
			best, bestTotal = p, total
		}
	}
	return best
}

// mdNamedForPool: one of the array's member devices carries md's name for the pool
// ("<host>:recasanix-data").
func (inv *Inventory) mdNamedForPool(physical []Block, a *RAIDArray) bool {
	for _, m := range a.Members {
		named := false
		for _, d := range physical {
			walk(d, func(b Block) {
				if b.Name == m.Name && b.FSType == "linux_raid_member" &&
					(b.Label == inv.cfg.PoolLabel || strings.HasSuffix(b.Label, ":"+inv.cfg.PoolLabel)) {
					named = true
				}
			})
		}
		if named {
			return true
		}
	}
	return false
}

// isPoolMember: the disk holds the pool's filesystem, or is a member of its md array.
func (inv *Inventory) isPoolMember(d Block, p *Pool) bool {
	member := false
	walk(d, func(b Block) {
		for _, m := range p.Members {
			if m.Name == b.Name {
				member = true
			}
		}
		for _, m := range p.members {
			if m.Path == b.Path {
				member = true
			}
		}
	})
	return member
}

// verbs fills in what can be asked of the pool and of each drive now.
func (v *storageView) verbs() {
	p := v.pool
	free := len(v.free()) > 0
	for i := range v.drives {
		d := &v.drives[i]
		switch d.Role {
		case "free":
			if p == nil {
				d.Verbs = append(d.Verbs, "create-pool")
			} else if p.Mounted && p.idle() {
				d.Verbs = append(d.Verbs, "add-disk", "replace-disk")
			}
		case "foreign":
			d.Verbs = append(d.Verbs, "wipe-disk")
		case "member":
			if p.Mounted && p.idle() && p.canRemove() {
				d.Verbs = append(d.Verbs, "remove-disk")
			}
			if p.Mounted && p.idle() && free {
				d.Verbs = append(d.Verbs, "replace-disk")
			}
		}
	}
	if p == nil {
		return
	}
	switch {
	case !p.Mounted && (p.State == "inactive" || p.Missing > 0):
		p.Verbs = append(p.Verbs, "mount-degraded")
	case !p.Mounted:
	case p.Action == "check" || p.State == "checking":
		p.Verbs = append(p.Verbs, "cancel-check")
	case p.idle():
		if free {
			p.Verbs = append(p.Verbs, "add-disk", "replace-disk")
		}
		if p.canRemove() {
			p.Verbs = append(p.Verbs, "remove-disk")
		}
		if p.Backend == "btrfs" && p.array != nil && p.array.mixed && p.LayoutKnown {
			p.Verbs = append(p.Verbs, "restore-layout")
		}
		if p.Backend == "btrfs" && len(p.layoutTargets()) > 0 {
			p.Verbs = append(p.Verbs, "change-layout")
		}
		p.Verbs = append(p.Verbs, "check")
	}
}

// idle: nothing long runs on the pool (a rebuild, a conversion, a resync); a degraded pool is idle.
func (p *Pool) idle() bool {
	return p.Action == "idle" && p.State != "rebuilding" && p.State != "reshaping" && p.State != "resyncing"
}

// present is the members the pool has now (not missing, not failed).
func (p *Pool) present() []PoolMember {
	var present []PoolMember
	for _, m := range p.Members {
		if m.State == "active" || m.State == "rebuilding" {
			present = append(present, m)
		}
	}
	return present
}

// canRemove: a member can go without making the layout impossible (btrfs), or a failed / spare
// member can be taken out (md).
func (p *Pool) canRemove() bool {
	if p.Backend == "md" {
		for _, m := range p.Members {
			if m.State == "faulty" || m.State == "spare" {
				return true
			}
		}
		return false
	}
	return p.LayoutKnown && len(p.Members) > 1 && len(p.present())-1 >= p.Layout.MinDisks()
}

// layoutTargets are the other btrfs layouts the pool's present disks allow.
func (p *Pool) layoutTargets() []Layout {
	var targets []Layout
	for _, l := range layouts {
		if l.Backend() == "btrfs" && (!p.LayoutKnown || l != p.Layout) && len(p.present()) >= l.MinDisks() {
			targets = append(targets, l)
		}
	}
	return targets
}
