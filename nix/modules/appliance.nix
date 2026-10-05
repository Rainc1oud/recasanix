# Task 2.2 — base appliance policy: identity, access, network exposure, boot, logging.
#
# Cold layer vs hot state (AGENTS.md §2): Nix owns what changes rarely and fleet-wide — packages,
# service enablement, firewall, boot, drivers. Users, shares, pools and apps are *hot state*, mutated
# at runtime through the CasaOS UI/API (its own databases, generated config + a service reload),
# exactly like every other NAS OS. So this module deliberately does NOT freeze the user database.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.recasanix.appliance;
in
{
  options.recasanix.appliance = {
    admin = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "admin";
        description = "Login of the vendor bootstrap administrator (created at first activation).";
      };
      authorizedKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "SSH public keys allowed to log in as the bootstrap administrator. SSH is key-only.";
      };
      initialHashedPassword = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Optional initial console password hash (from `mkpasswd`) for the bootstrap administrator. It
          is applied when the account is created and never overwritten afterwards, so a password
          changed at runtime survives image updates. Null means no password login. Prototype/VM
          configurations may set one; the product image must not ship a shared password.
        '';
      };
    };
  };

  config = {
    networking.hostName = "recasanix";

    # Hot state: ordinary useradd/PAM-style user management. /etc/passwd, /etc/shadow and /etc/group
    # are merged with the declared accounts at activation and must be kept on the writable state
    # partition (task 3.2) so runtime-created users survive image updates.
    users.mutableUsers = true;
    users.users.${cfg.admin.name} = {
      isNormalUser = true;
      description = "ReCasaNix bootstrap administrator";
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = cfg.admin.authorizedKeys;
      inherit (cfg.admin) initialHashedPassword;
    };
    # Prototype: the administrator authenticates by key and has no password to type into sudo.
    # TODO(hardening): revisit once first-run provisioning exists.
    security.sudo.wheelNeedsPassword = false;

    services.openssh = {
      enable = true;
      openFirewall = false; # ports are declared once, below
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    # Only the web UI (80/443), SSH and — when it is enabled — SMB are reachable.
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [
        22
        80
        443
      ]
      ++ lib.optionals config.services.samba.enable [
        139
        445
      ];
      allowedUDPPorts = lib.optionals config.services.samba.enable [
        137
        138
      ];
    };

    # CasaOS reads /etc/localtime (app management warns "cannot read symbolic link" without it) and lets
    # the operator change the timezone (timedatectl): a UTC default that is never overwritten (`L`), so
    # the choice is hot state and not declared here.
    systemd.tmpfiles.rules = [ "L /etc/localtime - - - - ${pkgs.tzdata}/share/zoneinfo/UTC" ];

    boot.loader.systemd-boot.enable = true;
    # The appliance image is written by dd/repart, not installed on a running machine; do not touch
    # the firmware's boot variables from the OS.
    boot.loader.efi.canTouchEfiVariables = lib.mkDefault false;

    # No Nix daemon on the device: updates arrive as whole images (AGENTS.md §2).
    nix.enable = false;

    services.journald.settings.Journal = {
      SystemMaxUse = "200M";
      RuntimeMaxUse = "50M";
      MaxRetentionSec = "1month";
    };

    system.stateVersion = "26.05";
  };
}
