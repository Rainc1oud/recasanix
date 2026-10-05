# Task 2.1 — the data pool: a *convention* plus monitoring, not a topology.
#
# Pool and dataset topology is hot state and always imperative (AGENTS.md §2): no NAS OS, TrueNAS
# included, declares its pools through system configuration — they are created, extended and
# repaired at runtime with mkfs.btrfs/btrfs (or zpool/zfs), driven by the UI/API. So this module never
# lists devices and never formats anything. It provides the cold, per-image parts only:
#
#   * the kernel/userland support for btrfs,
#   * the mount convention — a filesystem labelled `recasanix-data` appears at `mountPoint`,
#   * scrubbing and SMART monitoring.
#
# Reference operations for the runtime layer (first-run UX, storage API):
#
#   single:  mkfs.btrfs -L recasanix-data /dev/nvme0n1
#   mirror:  mkfs.btrfs -L recasanix-data -d raid1 -m raid1 /dev/sda /dev/sdb
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.recasanix.storage;

  poolFileSystems.${cfg.mountPoint} = {
    device = "/dev/disk/by-label/${cfg.poolLabel}";
    fsType = "btrfs";
    options = [
      # Mounted on first access instead of at boot. Without a pool the mountpoint then *fails* to
      # be used rather than silently writing into the small root device (Docker's data-root and the
      # CasaOS shares live below it), and a diskless or blank-disk machine boots with nothing failed.
      "noauto"
      "x-systemd.automount"
      "x-systemd.device-timeout=10s"
      "noatime"
      "compress=zstd"
    ];
  };
in
{
  options.recasanix.storage = {
    poolLabel = lib.mkOption {
      type = lib.types.str;
      default = "recasanix-data";
      description = ''
        Filesystem label that marks the data pool. Whatever runtime tooling creates the pool must
        label it with this; btrfs then assembles all member devices by itself (a mirror missing a
        member does not mount until it is explicitly mounted `degraded`, a runtime decision).

        ZFS is kept as a documented, commented-out alternative at the bottom of
        `nix/modules/storage.nix`. It is not an option here on purpose: ZFS is CDDL-licensed
        (redistribution needs review against the product's licence) and out-of-tree, so every nixpkgs
        kernel bump has to wait for a compatible ZFS. Flip it as an experiment by following the
        comments there and re-running the storage test (T3) against it.
      '';
    };

    dataRoot = lib.mkOption {
      type = lib.types.path;
      default = "/DATA";
      description = ''
        The data root CasaOS presents (upstream's convention, and hardcoded in app-store compose files as
        `/DATA/AppData/$AppID/…`). When the pool is present, its `DATA` directory is bind-mounted here
        (`DATA.mount`), so shares and app data land on the pool; the directory itself always exists on the
        root filesystem, because the root service pins it at startup and must come up before any pool.
        Whoever creates the pool creates `DATA` in it, and restarts the root service after mounting.
      '';
    };

    mountPoint = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/recasanix/data";
      description = "Where the data pool is mounted (CasaOS shares and Docker volumes live below it).";
    };
  };

  config = lib.mkMerge [
    {
      fileSystems = poolFileSystems;

      services.btrfs.autoScrub = {
        enable = true;
        fileSystems = [ cfg.mountPoint ];
        interval = "monthly";
      };

      environment.systemPackages = [ pkgs.btrfs-progs ];

      # The pool's DATA directory appears at the data root when the pool is present. A mount unit rather
      # than a `fileSystems` entry: with no pool it must be *skipped* (condition), not failed, and it
      # must not trigger the pool's automount (a 10 s wait on a diskless machine) — hence the check on
      # the device node instead of the path.
      systemd.mounts = [
        {
          what = "${cfg.mountPoint}/DATA";
          where = cfg.dataRoot;
          type = "none";
          options = "bind";
          wantedBy = [ "multi-user.target" ];
          unitConfig = {
            ConditionPathExists = "/dev/disk/by-label/${cfg.poolLabel}";
            RequiresMountsFor = cfg.mountPoint;
          };
        }
      ];
      systemd.tmpfiles.rules = [ "d ${cfg.dataRoot} 0755 root root -" ];

      # SMART warnings are an explicit product requirement. Notifications go to the journal only
      # (smartd logs there itself); no mail, no wall, no desktop popups. `-q nodev0` keeps smartd
      # from failing in machines without SMART-capable disks (VMs).
      services.smartd = {
        enable = true;
        autodetect = true;
        extraOptions = [
          "-q"
          "nodev0"
        ];
        notifications.wall.enable = false;
      };
    }

    # qemu-vm.nix (the VM runner and every NixOS VM test) replaces the *whole* `fileSystems` set with
    # its own `virtualisation.fileSystems`, silently dropping the pool mount. Feed it ours so the VM
    # mounts the pool exactly like the hardware does. The option only exists in VM contexts.
    (lib.optionalAttrs (options ? virtualisation.fileSystems) {
      virtualisation.fileSystems = poolFileSystems;
    })
  ];

  # ---------------------------------------------------------------------------------------------
  # ZFS alternative (NOT active). To try it, replace the btrfs `fileSystems`/`autoScrub` parts above
  # with the following — every line is needed:
  #
  #   boot.supportedFilesystems = [ "zfs" ];
  #   # ZFS lags the newest kernels: pin one nixpkgs supports, e.g.
  #   # boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
  #   boot.zfs.extraPools = [ "recasanix" ];       # imported at boot if present; created at runtime
  #   boot.zfs.forceImportRoot = false;
  #   networking.hostId = "8425e349";            # mandatory for ZFS; must be unique per device
  #   services.zfs.autoScrub.enable = true;
  #   services.zfs.trim.enable = true;
  #   fileSystems.${cfg.mountPoint} = { device = "recasanix/data"; fsType = "zfs"; options = [ "nofail" ]; };
  #
  # Runtime operations, like the btrfs ones at the top of this file:
  #   single:  zpool create -o ashift=12 recasanix /dev/nvme0n1 && zfs create recasanix/data
  #   mirror:  zpool create -o ashift=12 recasanix mirror /dev/sda /dev/sdb && zfs create recasanix/data
  #
  # Caveats to keep in mind before flipping it:
  #   * CDDL (ZFS) vs GPL (kernel): fine to build and use, but shipping a *distributed image* that
  #     contains the ZFS module needs a licensing review.
  #   * Kernel coupling: the pool's module must build against the kernel in the image; a nixpkgs
  #     bump can be blocked until ZFS catches up. btrfs is in-tree and has no such coupling.
  #   * RAM: ARC wants memory; with the 4 GB baseline cap it (boot.kernelParams =
  #     [ "zfs.zfs_arc_max=536870912" ]).
  #   * Then run storage test T3 against the ZFS variant (`zpool status` instead of
  #     `btrfs filesystem df`).
  # ---------------------------------------------------------------------------------------------
}
