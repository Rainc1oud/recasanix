# The development/test machine: the appliance modules on a QEMU VM. Task 2.2 needs it to evaluate and
# build; task 4.1 grows it into the runnable VM (`vm.nix` overlay: OVMF, serial console, port
# forwards, blank disks), services.recasaos (3.1) is enabled here.
{ lib, ... }:
{
  imports = [
    ../modules/appliance.nix
    ../modules/storage.nix
    ../modules/state.nix
    ../modules/docker.nix
    ../modules/vm.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  # (the recasaos module and its overlay are added by flake.nix)
  services.recasaos.enable = true;

  recasanix = {
    docker.enable = true;
    state.enable = true; # hot state; the VM variant gives it its own persistent disk (vm.nix)

    # DEVELOPMENT VM ONLY — a well-known console password ("recasanix") so the VM is usable headlessly.
    # The hardware image must never carry it: the product image sets SSH keys instead (task 4.3).
    appliance.admin.initialHashedPassword = "$6$devonlysalt12345$WwFKdMp4DEEe/.hPkereFfiMcpA3xDle9hxG4n8Gc7cYebb/Dbtut40Wewv/enzR3Vv54NqHLtCdT8WKK/oE40";
  };

  # Placeholder root so the closure evaluates; the VM runner (4.1) and the image (4.2) replace it.
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
}
