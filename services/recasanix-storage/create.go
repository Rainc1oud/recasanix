package main

import (
	"context"
	"fmt"
	"path"
)

// Creator turns a blank disk into storage: the same steps the documentation has a person type by hand
// (TESTING.md, docs/flashing.md), automated behind the UI's "Create Storage" button.
//
// There is exactly one pool, labelled Config.PoolLabel (the appliance's convention, not a user choice —
// the "Storage name" field the UI collects is not used for anything here). The first disk formats it;
// every later disk is added to it with btrfs's default "single" profile: capacity is additive, JBOD,
// no redundancy. There is no UI flow yet for asking for a mirror instead.
//
// The caller (API.createStorage) has already re-checked, against a fresh listing, that the disk is
// currently blank, unused, big enough and not the system disk — Creator does not re-decide any of that,
// it only acts. Every argument to every command is either a fixed literal or that one disk path.
type Creator struct {
	run Runner
	cfg Config
}

func newCreator(run Runner, cfg Config) *Creator { return &Creator{run: run, cfg: cfg} }

// poolExists reports whether any block device already carries the pool's label — i.e. whether Create
// should extend the pool instead of making it.
func poolExists(blocks []Block, label string) bool {
	found := false
	for _, b := range blocks {
		walk(b, func(x Block) {
			if x.Label == label {
				found = true
			}
		})
	}
	return found
}

// Create formats devicePath as the pool, or adds it to the pool if one already exists.
func (c *Creator) Create(ctx context.Context, devicePath string) error {
	blocks, err := listBlocks(ctx, c.run)
	if err != nil {
		return fmt.Errorf("list block devices: %w", err)
	}

	if poolExists(blocks, c.cfg.PoolLabel) {
		if _, err := c.run.Run(ctx, "btrfs", "device", "add", "-f", "--", devicePath, c.cfg.PoolMountPoint); err != nil {
			return fmt.Errorf("add %s to the existing pool: %w", devicePath, err)
		}
	} else {
		if _, err := c.run.Run(ctx, "mkfs.btrfs", "-f", "-L", c.cfg.PoolLabel, "--", devicePath); err != nil {
			return fmt.Errorf("format %s: %w", devicePath, err)
		}
	}

	// The pool's new (or newly grown) filesystem needs a moment for udev to catch up — the automount
	// below is keyed on /dev/disk/by-label/<PoolLabel>, which a fresh mkfs has not created yet.
	if _, err := c.run.Run(ctx, "udevadm", "settle", "--timeout=10"); err != nil {
		return fmt.Errorf("wait for udev: %w", err)
	}

	return c.bringOnline(ctx)
}

// bringOnline is exactly the manual sequence documented in TESTING.md: touching the DATA directory
// triggers the pool's systemd automount, then the bind mount and the two services that hold handles on
// it are (re)started. The mountpoint check turns a silent miss (mkdir landing on the un-mounted root
// filesystem instead of the pool) into a clear error instead of a running system with the wrong /DATA.
func (c *Creator) bringOnline(ctx context.Context) error {
	dataDir := path.Join(c.cfg.PoolMountPoint, path.Base(c.cfg.DataRoot))
	if _, err := c.run.Run(ctx, "mkdir", "-p", "--", dataDir); err != nil {
		return fmt.Errorf("create %s: %w", dataDir, err)
	}
	if _, err := c.run.Run(ctx, "mountpoint", "-q", "--", c.cfg.PoolMountPoint); err != nil {
		return fmt.Errorf("%s did not mount", c.cfg.PoolMountPoint)
	}
	if _, err := c.run.Run(ctx, "systemctl", "start", "--", "DATA.mount", "docker.service"); err != nil {
		return fmt.Errorf("start DATA.mount and docker: %w", err)
	}
	if _, err := c.run.Run(ctx, "systemctl", "restart", "--", "casaos.service", "casaos-app-management.service"); err != nil {
		return fmt.Errorf("restart casaos and casaos-app-management: %w", err)
	}
	return nil
}
