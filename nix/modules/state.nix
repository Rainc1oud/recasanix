# Task 3.2 — the cold/hot state boundary (AGENTS.md §2, "Cold vs hot state" and "Baseline + include").
#
# The system closure is cold, replaceable and vendor-managed. Everything users create through the
# appliance — accounts, ReCasaOS databases and configuration, SSH host keys — is *hot state*: it lives on
# one writable filesystem, `recasanix.state.mountPoint`, and survives both reboots and image updates (a
# fresh root). Nix supplies the immutable baseline and the places; it never regenerates the hot part.
#
# What lives where is the decision table in DEVELOPMENT.md ("State boundary").
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.recasanix.state;
  mp = cfg.mountPoint;

  # Account databases of `users.mutableUsers = true`, plus the uid/gid allocation maps.
  accountFiles = [
    "passwd"
    "shadow"
    "group"
    "gshadow"
    "subuid"
    "subgid"
  ];

  # Samba's passdb and secrets (share-account passwords): hot state.
  sambaBind."/var/lib/samba" = {
    device = "${mp}/samba";
    fsType = "none";
    options = [ "bind" ];
  };

  stateFileSystem.${mp} = {
    inherit (cfg) device autoFormat;
    fsType = "ext4";
    options = [ "noatime" ];
    # Needed by the activation scripts (account restore) and by every hot-state consumer, so it is
    # mounted in the initrd, before the system starts.
    neededForBoot = true;
  };

  accountsSync = pkgs.writeShellApplication {
    name = "recasanix-accounts-sync";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      dest=${mp}/accounts
      install -d -m 0700 "$dest"
      for f in ${lib.escapeShellArgs accountFiles}; do
        if [ -e "/etc/$f" ]; then
          cp -p "/etc/$f" "$dest/.$f.tmp"
          mv -f "$dest/.$f.tmp" "$dest/$f"
        fi
      done
    '';
  };
in
{
  options.recasanix.state = {
    enable = lib.mkEnableOption "the writable hot-state filesystem (accounts, ReCasaOS data and config, SSH host keys)";

    device = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/dev/disk/by-label/recasanix-state";
      description = ''
        Device holding the hot state (an ext4 filesystem — the `state` partition of the disk image).
        Null keeps it as a plain directory on the root filesystem: fine for throw-away development and
        most tests, but then hot state does not survive replacing the root, i.e. an image update.
      '';
    };

    mountPoint = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/recasanix/state";
      description = "Where the hot-state filesystem is mounted.";
    };

    autoFormat = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Create the filesystem on first boot if `device` is blank. Only for virtual machines and tests —
        on hardware the image build creates the partition and its filesystem.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf (cfg.device != null) { fileSystems = stateFileSystem; })

      # qemu-vm.nix replaces the whole `fileSystems` set with `virtualisation.fileSystems` (see storage.nix).
      (lib.optionalAttrs (options ? virtualisation.fileSystems) {
        virtualisation.fileSystems = lib.mkIf (cfg.device != null) stateFileSystem;
      })

      (lib.mkIf config.services.samba.enable { fileSystems = sambaBind; })
      (lib.optionalAttrs (options ? virtualisation.fileSystems) {
        virtualisation.fileSystems = lib.mkIf config.services.samba.enable sambaBind;
      })

      {
        # ReCasaOS: databases, user data and configuration move onto the state filesystem (the module
        # bind-mounts them at /var/lib/casaos and /etc/casaos, so nothing in the services needs to change).
        services.recasaos = {
          dataDir = lib.mkDefault "${mp}/casaos";
          configDir = lib.mkDefault "${mp}/casaos-etc";
          # the hot-state filesystem is plumbing: it must not show up as storage a user could put apps on
          storage.hiddenMounts = [ mp ];
        };

        # SSH host keys: a device that changed identity with every image update would keep breaking
        # clients' known_hosts.
        services.openssh.hostKeys = [
          {
            path = "${mp}/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
          {
            path = "${mp}/ssh/ssh_host_rsa_key";
            type = "rsa";
            bits = 4096;
          }
        ];

        # Accounts (`users.mutableUsers = true`): NixOS keeps them in /etc, which an image update
        # replaces. Restore them from the state filesystem *before* the users activation merges in the
        # declared accounts, and mirror every change back. /var/lib/nixos holds the uid/gid allocation
        # maps that keep declared users' ids stable.
        system.activationScripts.recasanixAccounts = {
          deps = [ "specialfs" ];
          text = ''
            # (the bind-mount sources of the ReCasaOS directories must exist before local-fs mounts them)
            mkdir -p ${mp}/accounts ${mp}/nixos ${mp}/samba ${config.services.recasaos.dataDir} ${config.services.recasaos.configDir}
            if [ ! -L /var/lib/nixos ]; then
              if [ -d /var/lib/nixos ] && [ -z "$(ls -A ${mp}/nixos)" ]; then
                cp -a /var/lib/nixos/. ${mp}/nixos/
              fi
              rm -rf /var/lib/nixos
              ln -s ${mp}/nixos /var/lib/nixos
            fi
            for f in ${lib.escapeShellArgs accountFiles}; do
              if [ -e "${mp}/accounts/$f" ]; then
                cp -p "${mp}/accounts/$f" "/etc/$f.recasanix-restore"
                mv -f "/etc/$f.recasanix-restore" "/etc/$f"
              fi
            done
          '';
        };
        system.activationScripts.users.deps = [ "recasanixAccounts" ];

        # Mirroring. Three triggers, because none alone is reliable: the accounts tools replace files by
        # rename, which a path unit on the *file* did not see in practice (found in the VM: a user created
        # at runtime never reached the state filesystem). So watch /etc itself (cheap: six small files
        # compared and copied), add a periodic run as a backstop, and a final copy at clean shutdown.
        systemd = {
          tmpfiles.rules = [
            "d ${mp} 0755 root root -"
            "d ${mp}/ssh 0700 root root -"
          ];

          services = {
            recasanix-accounts-sync = {
              description = "Mirror the account databases to the hot-state filesystem";
              wantedBy = [ "multi-user.target" ]; # also once at boot
              unitConfig = {
                RequiresMountsFor = mp;
                # one `useradd` = a burst of /etc changes (passwd, shadow, group, locks, backups) → path
                # triggers; the default start limit (5/10 s) then stopped mirroring for good. Cheap, idempotent
                # copy → no limit.
                StartLimitIntervalSec = 0;
              };
              serviceConfig = {
                Type = "oneshot";
                ExecStart = lib.getExe accountsSync;
              };
            };
            recasanix-accounts-final = {
              description = "Final mirror of the account databases at shutdown";
              wantedBy = [ "multi-user.target" ];
              unitConfig.RequiresMountsFor = mp;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "${pkgs.coreutils}/bin/true";
                ExecStop = lib.getExe accountsSync; # runs before the state filesystem is unmounted
              };
            };
          };

          paths.recasanix-accounts-sync = {
            wantedBy = [ "multi-user.target" ];
            pathConfig = {
              PathChanged = "/etc";
              Unit = "recasanix-accounts-sync.service";
            };
          };

          timers.recasanix-accounts-sync = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "1min";
              OnUnitActiveSec = "1min";
              Unit = "recasanix-accounts-sync.service";
            };
          };
        };
      }
    ]
  );
}
