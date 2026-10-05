package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// Block is one entry of `lsblk`'s tree: a disk, a partition, or a device stacked on one.
type Block struct {
	Name       string
	Path       string
	Type       string
	FSType     string
	Label      string
	UUID       string
	Model      string
	Serial     string
	Transport  string
	Size       uint64
	FSSize     uint64
	FSAvail    uint64
	FSUsed     uint64
	Mounts     []string
	Rotational bool
	Removable  bool
	Children   []Block
}

// lsblkColumns is everything this service reads. Naming the columns keeps the output small and the
// contract explicit; `--bytes` makes every size a plain number of bytes.
const lsblkColumns = "NAME,PATH,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,MODEL,SERIAL,TRAN,ROTA,RM,FSSIZE,FSAVAIL,FSUSED"

// listBlocks returns the block device tree as the kernel and udev see it right now.
func listBlocks(ctx context.Context, run Runner) ([]Block, error) {
	out, err := run.Run(ctx, "lsblk", "--json", "--bytes", "--output", lsblkColumns)
	if err != nil {
		return nil, fmt.Errorf("lsblk: %w", err)
	}
	return parseLsblk(out)
}

func parseLsblk(data []byte) ([]Block, error) {
	var doc struct {
		BlockDevices []rawBlock `json:"blockdevices"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("parse lsblk output: %w", err)
	}
	blocks := make([]Block, 0, len(doc.BlockDevices))
	for _, raw := range doc.BlockDevices {
		blocks = append(blocks, raw.block())
	}
	return blocks, nil
}

// rawBlock mirrors lsblk's JSON. Its value types have changed between util-linux releases (numbers
// or strings, "0"/"1" or true/false, one mountpoint or a list), so every field goes through a
// tolerant type and the rest of the service only sees Block.
type rawBlock struct {
	Name        flexString   `json:"name"`
	Path        flexString   `json:"path"`
	Type        flexString   `json:"type"`
	Size        flexUint     `json:"size"`
	FSType      flexString   `json:"fstype"`
	Label       flexString   `json:"label"`
	UUID        flexString   `json:"uuid"`
	MountPoints []flexString `json:"mountpoints"`
	MountPoint  flexString   `json:"mountpoint"`
	Model       flexString   `json:"model"`
	Serial      flexString   `json:"serial"`
	Tran        flexString   `json:"tran"`
	Rota        flexBool     `json:"rota"`
	RM          flexBool     `json:"rm"`
	FSSize      flexUint     `json:"fssize"`
	FSAvail     flexUint     `json:"fsavail"`
	FSUsed      flexUint     `json:"fsused"`
	Children    []rawBlock   `json:"children"`
}

func (r rawBlock) block() Block {
	b := Block{
		Name:       string(r.Name),
		Path:       string(r.Path),
		Type:       string(r.Type),
		FSType:     string(r.FSType),
		Label:      string(r.Label),
		UUID:       string(r.UUID),
		Model:      strings.TrimSpace(string(r.Model)),
		Serial:     strings.TrimSpace(string(r.Serial)),
		Transport:  string(r.Tran),
		Size:       uint64(r.Size),
		FSSize:     uint64(r.FSSize),
		FSAvail:    uint64(r.FSAvail),
		FSUsed:     uint64(r.FSUsed),
		Rotational: bool(r.Rota),
		Removable:  bool(r.RM),
	}
	for _, m := range r.MountPoints {
		if m != "" {
			b.Mounts = append(b.Mounts, string(m))
		}
	}
	if len(b.Mounts) == 0 && r.MountPoint != "" { // older lsblk: a single mountpoint
		b.Mounts = []string{string(r.MountPoint)}
	}
	for _, c := range r.Children {
		b.Children = append(b.Children, c.block())
	}
	return b
}

type flexString string

func (f *flexString) UnmarshalJSON(b []byte) error {
	if string(b) == "null" {
		*f = ""
		return nil
	}
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	*f = flexString(s)
	return nil
}

type flexUint uint64

func (f *flexUint) UnmarshalJSON(b []byte) error {
	s := strings.Trim(strings.TrimSpace(string(b)), `"`)
	if s == "" || s == "null" {
		*f = 0
		return nil
	}
	v, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		return fmt.Errorf("not a number of bytes: %q", s)
	}
	*f = flexUint(v)
	return nil
}

type flexBool bool

func (f *flexBool) UnmarshalJSON(b []byte) error {
	switch strings.Trim(strings.TrimSpace(string(b)), `"`) {
	case "true", "1":
		*f = true
	case "false", "0", "", "null":
		*f = false
	default:
		return fmt.Errorf("not a boolean: %s", b)
	}
	return nil
}
