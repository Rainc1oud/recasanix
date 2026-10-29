package main

import (
	"fmt"
	"slices"
)

// Layout is how a pool spreads data over its disks, in backend-neutral words (docs/storage-layer.md):
//
//	none           capacity adds up, no disk may fail          btrfs single
//	mirror copies  every block on `copies` disks               btrfs raid1 (2), raid1c3 (3)
//	parity p       p disks of parity                           md raid5 (1), raid6 (2), btrfs single on top
//
// Parity goes to md: btrfs's own raid5/6 is not safe for data (write hole).
type Layout struct {
	Kind   string `json:"kind"` // none, mirror, parity
	Copies int    `json:"copies,omitempty"`
	Parity int    `json:"parity,omitempty"`
}

// layouts is every layout a pool can be made with, simplest first.
var layouts = []Layout{
	{Kind: "none"},
	{Kind: "mirror", Copies: 2},
	{Kind: "mirror", Copies: 3},
	{Kind: "parity", Parity: 1},
	{Kind: "parity", Parity: 2},
}

func (l Layout) valid() bool { return slices.Contains(layouts, l) }

// Backend is what implements the layout.
func (l Layout) Backend() string {
	if l.Kind == "parity" {
		return "md"
	}
	return "btrfs"
}

// Tolerates is how many disks the layout can lose without losing data.
func (l Layout) Tolerates() int {
	switch l.Kind {
	case "mirror":
		return l.Copies - 1
	case "parity":
		return l.Parity
	}
	return 0
}

// MinDisks is the fewest disks the layout can be made of.
func (l Layout) MinDisks() int {
	switch l.Kind {
	case "mirror":
		return l.Copies
	case "parity":
		return l.Parity + 2
	}
	return 1
}

// Profile is the backend's own word for the layout.
func (l Layout) Profile() string {
	switch {
	case l.Kind == "mirror" && l.Copies == 2:
		return "raid1"
	case l.Kind == "mirror":
		return fmt.Sprintf("raid1c%d", l.Copies)
	case l.Kind == "parity" && l.Parity == 1:
		return "raid5"
	case l.Kind == "parity":
		return "raid6"
	}
	return "single"
}

// metadataProfile is the btrfs metadata profile for the layout on n devices: never less safe than the
// data, and two copies (dup on one device) at least.
func (l Layout) metadataProfile(n int) string {
	switch {
	case l.Kind == "mirror":
		return l.Profile()
	case l.Kind == "parity" || n == 1:
		return "dup" // one device: md below, or a single disk
	}
	return "raid1"
}

// String is the layout in a person's words.
func (l Layout) String() string {
	switch l.Kind {
	case "mirror":
		return fmt.Sprintf("Mirror, %d copies — survives %s failing", l.Copies, diskCount(l.Tolerates()))
	case "parity":
		if l.Parity == 1 {
			return "Parity (RAID 5) — survives 1 disk failing"
		}
		return "Double parity (RAID 6) — survives 2 disks failing"
	}
	return "No protection — capacity of all disks, no disk may fail"
}

// layoutOfProfile is the layout a btrfs data profile or an md level stands for; false when there is
// none (raid0, raid10, btrfs raid5/6, dup: made by hand, shown but not offered).
func layoutOfProfile(profile string) (Layout, bool) {
	for _, l := range layouts {
		if l.Profile() == profile {
			return l, true
		}
	}
	return Layout{}, false
}

// Capacity is about how many bytes of data the layout holds on disks of these sizes.
func (l Layout) Capacity(sizes []uint64) uint64 {
	if len(sizes) < l.MinDisks() {
		return 0
	}
	var sum, largest, smallest uint64
	smallest = sizes[0]
	for _, s := range sizes {
		sum += s
		largest = max(largest, s)
		smallest = min(smallest, s)
	}
	switch l.Kind {
	case "mirror":
		// btrfs puts each copy on a different device: the largest disk can only be matched by the others
		c := uint64(l.Copies)
		return min(sum/c, (sum-largest)/(c-1))
	case "parity":
		return uint64(len(sizes)-l.Parity) * smallest // md uses the smallest member's size on each
	}
	return sum
}

// diskCount is "1 disk", "2 disks".
func diskCount(n int) string {
	if n == 1 {
		return "1 disk"
	}
	return fmt.Sprintf("%d disks", n)
}
