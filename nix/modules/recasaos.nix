# Task 3.1 — `services.recasaos`: the five ReCasaOS services as native NixOS units.
#
# Translated by hand from upstream's build/sysroot/usr/lib/systemd/system/*.service (kept in
# `pkgs.casaos-sysroot` for reference) rather than dropping those files in, so ExecStart and every
# tool the services shell out to resolve to store paths through Nix, not through a Debian layout.
#
# State handling (task 3.2): hot files are seeded from upstream's samples on first use and never
# overwritten; vendor-owned ones are rebuilt every boot. `configDir` and `dataDir` are where they
# really live — `recasanix.state` points them at the writable state filesystem.
{
  config,
  options,
  utils,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.recasaos;
  sysroot = "${pkgs.casaos-sysroot}/share/casaos-sysroot";
  uiRoot = "${cfg.uiPackage}/share/casaos-sysroot";

  # Gateway config baseline: upstream's sample with the configured port filled in. Seeded once; the
  # gateway rewrites the file itself when the port is changed from the UI (hot state).
  gatewaySeed = pkgs.runCommand "gateway.ini" { } ''
    substitute ${sysroot}/etc/casaos/gateway.ini.sample $out \
      --replace-fail 'port=' 'port=${toString cfg.httpPort}'
  '';

  # Tools resolved from *inside* the shipped scripts (helper.sh, usb-mount.sh, register-ui-events.sh)
  # and by the root service; the unit's PATH is inherited by every child it spawns, so this list is the
  # appliance's effective privileged toolbox — keep it minimal and justified.
  rootPath = with pkgs; [
    bash # helper.sh's `#!/usr/bin/env bash` interpreter, and the `bash -c` the Go code spawns
    coreutils # cat, ls, uname, rm, mkdir …
    gawk
    gnugrep
    util-linux # lsblk, blkid, mount, umount, logger
    systemd # timedatectl
    procps # free (GetSysInfo)
    glibc.bin # getconf (GetSysInfo)
    curl # register-ui-events.sh (start.d) talks to the message bus
    smartmontools # SMART queries
    e2fsprogs # mkfs.ext4 …
    dosfstools
    ntfs3g
    exfatprogs
  ];

  # The services address /etc/casaos and /var/lib/casaos, and their hardened storage code refuses to
  # traverse symlinks ("open database directory component: not a directory"), so when the real
  # location differs (the state filesystem, task 3.2) it is *bind-mounted* there, not linked.
  binds =
    lib.optionalAttrs (cfg.configDir != "/etc/casaos") {
      "/etc/casaos" = {
        device = cfg.configDir;
        fsType = "none";
        options = [ "bind" ];
      };
    }
    // lib.optionalAttrs (cfg.dataDir != "/var/lib/casaos") {
      "/var/lib/casaos" = {
        device = cfg.dataDir;
        fsType = "none";
        options = [ "bind" ];
      };
    };

  stateInit = pkgs.writeShellApplication {
    name = "recasanix-state-init";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      config=${cfg.configDir}
      data=${cfg.dataDir}
      install -d -m 0755 "$config" "$data" "$data/db"

      # HOT state: created once from upstream's samples, never overwritten. (The services also write
      # these at runtime — the gateway rewrites gateway.ini when the port changes, app-management the
      # app-store list.) message-bus and user-service open their databases in $data/db; without the
      # directory their first start fails and only Restart=always papers over it.
      seed() { [ -e "$2" ] || install -m 0600 "$1" "$2"; }
      seed ${gatewaySeed} "$config/gateway.ini"
      seed ${sysroot}/etc/casaos/message-bus.conf.sample "$config/message-bus.conf"
      seed ${sysroot}/etc/casaos/user-service.conf.sample "$config/user-service.conf"
      seed ${sysroot}/etc/casaos/app-management.conf.sample "$config/app-management.conf"
      seed ${sysroot}/etc/casaos/casaos.conf.sample "$config/casaos.conf"
      seed /dev/null "$config/env" # app-management reads it at start; empty unless configured

      # VENDOR-owned, rebuilt on every boot: start.d is *executed* by the root service at startup, so
      # only the UI's event-registration hook may ever be in it (check T9 pins the shipped set too).
      rm -rf "$config/start.d"
      install -d -m 0755 "$config/start.d"
      ln -s ${uiRoot}/etc/casaos/start.d/register-ui-events.sh "$config/start.d/register-ui-events.sh"
      # ... and the UI tree the gateway serves plus the UI's message-bus event definitions.
      rm -rf "$data/www" "$data/ui-message-bus.json"
      ln -s ${uiRoot}/var/lib/casaos/www "$data/www"
      ln -s ${uiRoot}/var/lib/casaos/ui-message-bus.json "$data/ui-message-bus.json"
    '';
  };

  userAdmin = pkgs.writeShellApplication {
    name = "recasanix-user-admin";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
    ];
    text = builtins.readFile ./recasaos-user-admin.sh;
  };

  # The fork's local-only account lifecycle (docs/security-bootstrap.md in the user-service repo):
  # disabled oneshots, never wantedBy anything, credentials loaded from root-only /run files.
  mkAccountOneshot =
    {
      description,
      subcommand,
      dir,
      files, # credential name -> source file name
      conflicts,
    }:
    {
      inherit description conflicts;
      before = [ "casaos-user-service.service" ];
      # Not enabled: an administrator starts it explicitly (recasanix-user-admin).
      serviceConfig = {
        Type = "oneshot";
        LoadCredential = lib.mapAttrsToList (name: file: "${name}:${dir}/${file}") files;
        ExecStart = "${lib.getExe pkgs.casaos-user-service} ${subcommand} -c /etc/casaos/user-service.conf";
        ExecStopPost = "-${pkgs.coreutils}/bin/rm -f -- ${
          lib.concatMapStringsSep " " (f: "${dir}/${f}") (lib.attrValues files)
        }";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
      };
    };

  # The pool's DATA directory is bind-mounted over a file root when the pool is present; the root service
  # pins its roots at startup, so it must start after that mount (the unit is skipped without a pool).
  rootMounts = map (r: "${utils.escapeSystemdPath r}.mount") cfg.fileRoots;

  mkUnit =
    {
      description,
      exe,
      args ? "",
      after ? [ ],
      path ? [ ],
      environment ? { },
      conflicts ? [ ],
      serviceConfig ? { },
    }:
    {
      inherit
        description
        path
        environment
        conflicts
        ;
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "recasanix-state-init.service"
      ]
      ++ after;
      requires = [ "recasanix-state-init.service" ];
      # Upstream: Type=notify, Restart=always. (Upstream's ExecStartPre=<bin> -v only prints the
      # version and is dropped. PIDFile= is dropped too: notify readiness makes it redundant.)
      serviceConfig = {
        Type = "notify";
        Restart = "always";
        ExecStart = "${lib.getExe exe}${lib.optionalString (args != "") " ${args}"}";
      }
      // serviceConfig;
    };
in
{
  options.services.recasaos = {
    enable = lib.mkEnableOption "the ReCasaOS management layer (web UI, files, users, app management)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.casaos;
      defaultText = lib.literalExpression "pkgs.casaos";
      description = "The ReCasaOS root service.";
    };

    uiPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.casaos-ui;
      defaultText = lib.literalExpression "pkgs.casaos-ui";
      description = "The web UI; its `www/` tree is served by the gateway from `dataDir/www`.";
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 80;
      description = ''
        Port the gateway listens on. This only seeds a missing gateway.ini: the port can be changed
        from the UI afterwards, and that change is hot state that survives image updates.
      '';
    };

    fileRoots = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ "/DATA" ];
      description = ''
        Directories the root service is allowed to manage (browse, share). It pins them at startup and
        refuses to start if one is missing, so they are created here on the root filesystem — the
        appliance must come up, and show its UI, even before a data pool exists. Pools and datasets
        are mounted below these at runtime (hot state), not declared here. Upstream's default
        (/DATA, /mnt, /media) is narrowed to the one that has a role on this appliance.
      '';
    };

    configDir = lib.mkOption {
      type = lib.types.path;
      default = "/etc/casaos";
      description = ''
        Where the services' configuration really lives. They address `/etc/casaos`; when this differs,
        it is bind-mounted there. The directory holds *hot* files (gateway port, app-store sources, the
        bootstrap seal…), seeded from upstream's samples on first use and never overwritten, plus a
        vendor-owned `start.d` rebuilt on every boot (see `recasanix.state`, task 3.2).
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/casaos";
      description = ''
        Where ReCasaOS really keeps its databases and data. The services address `/var/lib/casaos`;
        when this differs, it is bind-mounted there (`recasanix.state` points it at the writable state
        filesystem).
      '';
    };

    storage = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          The storage manager behind the UI's storage widget (`recasanix-storage`): a small service that
          lists the machine's disks and volumes, and can turn a blank disk into storage, on the routes
          the UI already calls. The pinned ReCasaOS has no storage service of its own, so without this
          the widget's manager is defunct. Formatting or removing an *existing* storage, and merging
          storages, are refused with a message that says so (docs/storage-manager.md).
        '';
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.recasanix-storage;
        defaultText = lib.literalExpression "pkgs.recasanix-storage";
        description = "The storage manager.";
      };

      hiddenMounts = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = ''
          Mount points of volumes that are system plumbing and must not be offered as storage
          (`recasanix.state` adds the hot-state filesystem).
        '';
      };

      minDiskSize = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 1024 * 1024 * 1024; # 1 GiB
        description = ''
          The smallest disk, in bytes, offered for creating storage — filters out devices too small to
          plausibly be a data disk. Does not affect disks already part of the pool.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        fileSystems = binds;

        environment.systemPackages = [ userAdmin ];

        systemd = {
          services = {
            # gateway → message-bus → { casaos, user-service, app-management }  (upstream's order)
            casaos-gateway = mkUnit {
              description = "CasaOS Gateway";
              exe = pkgs.casaos-gateway;
            };

            casaos-message-bus = mkUnit {
              description = "CasaOS Message Bus Service";
              exe = pkgs.casaos-message-bus;
              args = "-c /etc/casaos/message-bus.conf";
              after = [ "casaos-gateway.service" ];
            };

            casaos-user-service = mkUnit {
              description = "CasaOS User Service";
              exe = pkgs.casaos-user-service;
              args = "-c /etc/casaos/user-service.conf";
              after = [ "casaos-message-bus.service" ];
              conflicts = [
                "recasaos-user-bootstrap.service"
                "recasaos-user-password-reset.service"
              ];
              # The fork's hardening: account data is never group/world readable.
              serviceConfig.UMask = "0077";
            };

            casaos-app-management = mkUnit {
              description = "CasaOS App Management Service";
              exe = pkgs.casaos-app-management;
              args = "-c /etc/casaos/app-management.conf";
              # Docker (recasanix.docker) is skipped when there is no data pool; ordering is then a no-op.
              after = rootMounts ++ [
                "casaos-message-bus.service"
                "docker.service"
              ];
            };

            # Upstream also orders this After=rclone.service. Cloud-drive mounting is not a product
            # feature, so rclone is neither shipped nor waited for.
            casaos = mkUnit {
              description = "CasaOS Main Service";
              exe = cfg.package;
              args = "-c /etc/casaos/casaos.conf";
              after = rootMounts ++ [ "casaos-message-bus.service" ];
              path = rootPath;
              environment.RECASAOS_MANAGEMENT_FILE_ROOTS = lib.concatStringsSep "," cfg.fileRoots;
            };

            # Read-only storage manager (the UI's storage widget). It registers its routes with the
            # gateway using the gateway's service token, which is why it runs as root: the token file is
            # owner-only. Everything else about it is locked down — it reads block devices and changes
            # nothing on the machine.
            recasanix-storage = lib.mkIf cfg.storage.enable (mkUnit {
              description = "ReCasaNix storage manager";
              exe = cfg.storage.package;
              args = lib.escapeShellArgs (
                [
                  "-runtime-dir"
                  "/var/run/casaos"
                  "-data-root"
                  (lib.head cfg.fileRoots)
                  "-pool-label"
                  config.recasanix.storage.poolLabel
                  "-pool-mount"
                  config.recasanix.storage.mountPoint
                  "-min-disk-size"
                  (toString cfg.storage.minDiskSize)
                ]
                ++ lib.concatMap (m: [
                  "-hidden-mount"
                  m
                ]) cfg.storage.hiddenMounts
              );
              after = [
                "casaos-gateway.service"
                "casaos-user-service.service"
              ];
              # lsblk/mount/mountpoint for the inventory and bringing a new pool online, smartctl for
              # health and temperature, mkfs.btrfs/btrfs to create or extend the pool, udevadm to wait
              # for it, systemctl to start/restart the units the manual "make a pool" steps do.
              path = [
                pkgs.util-linux
                pkgs.coreutils
                pkgs.smartmontools
                pkgs.btrfs-progs
                pkgs.systemd
              ];
              serviceConfig = {
                # smartctl and mkfs.btrfs need raw disk access; lsblk needs to look at every mount point;
                # nothing else. This unit can format a disk chosen by an authenticated API caller — see
                # docs/storage-manager.md for why that is validated fresh on every request, not here.
                CapabilityBoundingSet = [
                  "CAP_DAC_READ_SEARCH" # look at every mount point, read-only
                  "CAP_SYS_RAWIO"
                  "CAP_SYS_ADMIN"
                ];
                NoNewPrivileges = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                PrivateTmp = true;
                ProtectKernelTunables = true;
                ProtectKernelModules = true;
                ProtectControlGroups = true;
                ProtectClock = true;
                ProtectHostname = true;
                RestrictSUIDSGID = true;
                RestrictNamespaces = true;
                RestrictRealtime = true;
                LockPersonality = true;
                MemoryDenyWriteExecute = true;
                SystemCallArchitectures = "native";
                # unix: sd_notify; inet: loopback to the gateway and the user service
                RestrictAddressFamilies = [
                  "AF_UNIX"
                  "AF_INET"
                  "AF_INET6"
                ];
              };
            });

            # Local-only account lifecycle; see recasanix-user-admin. Disabled oneshots.
            recasaos-user-bootstrap = mkAccountOneshot {
              description = "ReCasaOS one-time local administrator bootstrap";
              subcommand = "bootstrap-admin";
              dir = "/run/recasaos-user-bootstrap";
              files = {
                "recasaos.admin.username" = "username";
                "recasaos.admin.password" = "password";
              };
              conflicts = [
                "casaos-user-service.service"
                "recasaos-user-password-reset.service"
              ];
            };
            recasaos-user-password-reset = mkAccountOneshot {
              description = "ReCasaOS local administrator password reset";
              subcommand = "reset-admin-password";
              dir = "/run/recasaos-user-password-reset";
              files = {
                "recasaos.admin.username" = "username";
                "recasaos.admin.new-password" = "new-password";
              };
              conflicts = [
                "casaos-user-service.service"
                "recasaos-user-bootstrap.service"
              ];
            };
            recasaos-user-account-password-reset = mkAccountOneshot {
              description = "ReCasaOS local non-administrator password reset";
              subcommand = "reset-user-password";
              dir = "/run/recasaos-user-account-password-reset";
              files = {
                "recasaos.user.username" = "username";
                "recasaos.user.new-password" = "new-password";
              };
              conflicts = [
                "casaos-user-service.service"
                "recasaos-user-bootstrap.service"
                "recasaos-user-password-reset.service"
              ];
            };

            # Baseline seeding and vendor-owned refresh (task 3.2). Hot files are created once from
            # upstream's samples and never overwritten; vendor-owned entries are rebuilt on every boot, so
            # tampering with them (or an old image's leftovers) cannot survive a restart.
            recasanix-state-init = {
              description = "Seed and refresh ReCasaOS state (hot files once, vendor-owned files every boot)";
              wantedBy = [ "multi-user.target" ];
              before = [
                "casaos-gateway.service"
                "casaos-message-bus.service"
                "casaos-user-service.service"
                "casaos-app-management.service"
                "casaos.service"
              ];
              unitConfig.RequiresMountsFor = [
                cfg.configDir
                cfg.dataDir
              ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = lib.getExe stateInit;
              };
            };
          };

          # Removable-media mounting (usb-mount@.service, udev-triggered, hardcodes /DATA/USB_Storage_*) is
          # deferred: no template unit and no udev rule yet (owner decision: to be reinstated later); the
          # shipped usb-mount.sh stays in the sysroot for that.

          tmpfiles.rules = [
            "d ${cfg.configDir} 0755 root root -"
            "d ${cfg.dataDir} 0755 root root -"
            "d /var/run/casaos 0755 root root -"
            "d /var/log/casaos 0755 root root -"
            # credential drop directories of the local account oneshots (files are created on demand)
            "d /run/recasaos-user-bootstrap 0700 root root -"
            "d /run/recasaos-user-password-reset 0700 root root -"
            "d /run/recasaos-user-account-password-reset 0700 root root -"

            # The root service finds its helper scripts at upstream's ShellPath.
            "d /usr/share/casaos 0755 root root -"
            "L+ /usr/share/casaos/shell - - - - ${sysroot}/usr/share/casaos/shell"
          ]
          ++ map (root: "d ${root} 0755 root root -") cfg.fileRoots;
        };
      }

      # qemu-vm.nix replaces the whole `fileSystems` set with `virtualisation.fileSystems` (see storage.nix).
      (lib.optionalAttrs (options ? virtualisation.fileSystems) {
        virtualisation.fileSystems = binds;
      })
    ]
  );
}
