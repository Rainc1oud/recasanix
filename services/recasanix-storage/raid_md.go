package main

import (
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// mdArrays reads the Linux software RAID arrays from sysfs (/sys/block/md*/md), as upstream
// LocalStorage does: the parity pools (layout.go) and any array made by hand.
func (inv *Inventory) mdArrays(physical []Block, listedUnder map[string]string) []RAIDArray {
	dirs, _ := filepath.Glob(filepath.Join(inv.sys, "block", "md*", "md"))
	sort.Strings(dirs)
	// the md device as lsblk shows it (under each member disk): its filesystem
	onMD := map[string]Block{}
	for _, d := range physical {
		walk(d, func(b Block) {
			if strings.HasPrefix(b.Type, "raid") || b.Type == "md" {
				onMD[b.Name] = b
			}
		})
	}
	arrays := []RAIDArray{}
	for _, dir := range dirs {
		level := readSys(dir, "level")
		devs, _ := filepath.Glob(filepath.Join(dir, "dev-*"))
		sort.Strings(devs)
		// an array assembled but not started (a member missing at boot) has no level yet: it counts
		if level == "" && (readSys(dir, "array_state") != "inactive" || len(devs) == 0) {
			continue
		}
		name := filepath.Base(filepath.Dir(dir))
		a := RAIDArray{
			Name: name, Path: "/dev/" + name, Level: level, Action: "idle", Progress: -1, Remaining: -1,
			Disks: atoi(readSys(dir, "raid_disks")), Missing: atoi(readSys(dir, "degraded")),
			ComponentSize: int64(atoi(readSys(dir, "component_size"))) * 1024,
			Members:       []RAIDMember{},
			backend:       "md", device: "/dev/" + name,
		}
		if fs, ok := onMD[name]; ok {
			a.uuid = fs.UUID
			if fs.Label != "" {
				a.Name = fs.Label
			}
			if len(fs.Mounts) > 0 {
				a.mount = inv.chooseMount(fs.Mounts)
			}
			if under := listedUnder[fs.UUID]; under != "" {
				a.Path = under
			}
		}
		if action := readSys(dir, "sync_action"); action != "" {
			a.Action = action
		}
		if done, total, ok := sectorsDone(readSys(dir, "sync_completed")); ok && a.Action != "idle" {
			a.Progress = float64(done) * 100 / float64(total)
			if speed, err := strconv.ParseInt(readSys(dir, "sync_speed"), 10, 64); err == nil && speed > 0 {
				a.Remaining = (total - done) * 512 / (speed * 1024)
			}
		}
		for _, dev := range devs {
			member := strings.TrimPrefix(filepath.Base(dev), "dev-")
			flags := strings.Split(readSys(dev, "state"), ",")
			slot := readSys(dev, "slot")
			m := RAIDMember{Name: member, Disk: diskOf(inv.sys, member), State: "active", Errors: uint64(atoi(readSys(dev, "errors"))),
				size: uint64(a.ComponentSize)} // what md uses of each member
			switch {
			case hasFlag(flags, "faulty"):
				m.State = "faulty"
			case slot == "none" || slot == "":
				m.State = "spare"
			case !hasFlag(flags, "in_sync"):
				m.State = "rebuilding"
			}
			a.Members = append(a.Members, m)
		}
		if a.Disks == 0 { // not started: md does not say yet how many it should have
			a.Disks = len(a.Members)
		}
		a.State = mdState(readSys(dir, "array_state"), a)
		arrays = append(arrays, a)
	}
	return arrays
}

func hasFlag(flags []string, flag string) bool {
	for _, f := range flags {
		if f == flag {
			return true
		}
	}
	return false
}

// mdState: the same states as a btrfs (raid.go), from md's view.
func mdState(arrayState string, a RAIDArray) string {
	switch {
	case arrayState == "inactive" || arrayState == "clear" || arrayState == "broken" || arrayState == "":
		return "inactive"
	case a.Missing > 0 && (a.Action == "recover" || a.Action == "resync"):
		return "rebuilding"
	case a.Missing > 0:
		return "degraded"
	case a.Action == "resync":
		return "resyncing"
	case a.Action == "check" || a.Action == "repair":
		return "checking"
	case a.Action == "reshape":
		return "reshaping"
	}
	for _, m := range a.Members {
		if m.State == "faulty" {
			return "degraded"
		}
	}
	return "ok"
}

// sectorsDone reads md's "done / total" (sectors); false for "none".
func sectorsDone(value string) (int64, int64, bool) {
	done, total, ok := strings.Cut(value, "/")
	if !ok {
		return 0, 0, false
	}
	d, err1 := strconv.ParseInt(strings.TrimSpace(done), 10, 64)
	t, err2 := strconv.ParseInt(strings.TrimSpace(total), 10, 64)
	if err1 != nil || err2 != nil || t <= 0 || d < 0 || d > t {
		return 0, 0, false
	}
	return d, t, true
}

func atoi(s string) int {
	n, _ := strconv.Atoi(strings.TrimSpace(s))
	return n
}
