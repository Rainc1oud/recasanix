# Task 4.3 — the machine that becomes the hardware image (`packages.image`): the appliance modules on
# the N200 board, laid out by nix/modules/image.nix. Unlike recasanix-vm it carries no development
# conveniences: no well-known password, no port forwards, no placeholder root.
{ config, lib, ... }:
let
  keys = lib.filter (l: l != "" && !(lib.hasPrefix "#" l)) (
    map lib.trim (lib.splitString "\n" (builtins.readFile ./admin-authorized-keys))
  );
in
{
  imports = [
    ../modules/appliance.nix
    ../modules/storage.nix
    ../modules/state.nix
    ../modules/docker.nix
    ../modules/image.nix
    ../modules/hardware-n200.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  # (the recasaos module and its overlay are added by flake.nix)
  services.recasaos.enable = true;

  recasanix = {
    docker.enable = true;
    state.enable = true; # on its own partition (image.nix)
    appliance.admin.authorizedKeys = keys;
  };

  # The image has no password, so without a key nobody can ever log in to the flashed device. Say so
  # where it will be seen: at build time (the emulator's own banner is wiped by the firmware).
  warnings = lib.optional (config.recasanix.appliance.admin.authorizedKeys == [ ]) ''
    The hardware image has no SSH keys, so nobody can log in to it. Add your public key to
    nix/hosts/admin-authorized-keys (working copy only, never commit it) and rebuild (see docs/flashing.md).
  '';
}
