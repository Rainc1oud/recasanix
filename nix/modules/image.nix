# Task 4.2 — the disk image: a GPT layout that is A/B-capable now and RAUC-ready later (AGENTS.md §2).
#
#   #  partition           type          size    contents
#   1  recasa-esp          EFI System    512 MiB systemd-boot + the UKI of the running slot
#   2  recasanix-root-a    root-x86-64   8 GiB   the system (ext4), populated by this build
#   3  recasanix-root-b    root-x86-64   8 GiB   empty — reserved for the first RAUC update
#   4  recasanix-state     linux-generic 4 GiB   hot state (ext4): accounts, ReCasaOS data, SSH host keys
#   5  recasanix-data      (own type)    grows   blank; grown to the end of the disk on first boot
#
# The two root slots are the same size so a bundle that fits one fits the other. Only slot A boots for
# now: the root is named explicitly (fileSystems."/" below) instead of being discovered from the GPT
# type, which two root partitions would make ambiguous. Slot switching is the RAUC phase.
#
# The data partition is left blank on purpose. Pools are hot state and always created at runtime
# (nix/modules/storage.nix): whoever creates the pool runs, for the single-disk case,
#   mkfs.btrfs -L recasanix-data /dev/disk/by-partlabel/recasanix-data
# and the storage module mounts it by that filesystem label. All this image does is give the eMMC's
# remaining space a partition of its own and make sure it exists at the size the disk actually has.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) efiArch;

  # GPT partition names. Everything that refers to a partition does so through these.
  label = {
    esp = "recasa-esp"; # also the FAT volume label, which holds at most 11 characters
    rootA = "recasanix-root-a";
    rootB = "recasanix-root-b";
    state = "recasanix-state";
    data = "recasanix-data";
  };

  slotSize = "8G";

  # The data partition gets its own type UUID (generated once, fixed forever). Repart matches the
  # partitions it finds on the disk to its definitions by type, so a second `linux-generic` partition
  # next to `state` would be ambiguous when the initrd grows it.
  dataType = "ba64870a-584f-406f-b37a-ac7cda39b97e";

  # The one partition definition used twice: to create the partition in the image, and — in the initrd —
  # to recognise it on the device and grow it. Sizes here are the *minimum*; there is no maximum.
  dataPartition = {
    Type = dataType;
    Label = label.data;
    SizeMinBytes = "512M";
  };

  rootSlot = uuid: name: {
    Type = "root";
    Label = name;
    UUID = uuid;
    SizeMinBytes = slotSize;
    SizeMaxBytes = slotSize;
  };
in
{
  # Not part of the default module set.
  imports = [ "${modulesPath}/image/repart.nix" ];

  system.image = {
    id = "recasanix";
    # Bumped by hand for now; the update phase will derive it from the release tag.
    version = "0.1.0";
  };

  image.repart = {
    enable = true;
    name = "recasanix";
    # 512-byte sectors: firmware (and OVMF in particular) does not handle repart's 4096 default.
    sectorSize = 512;

    partitions = {
      "10-esp" = {
        contents = {
          "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
            "${config.systemd.package}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";

          # Boot at once; holding a key still opens the menu. No command-line editing: with a
          # headless appliance it is only ever a way to get a root shell.
          "/loader/loader.conf".source = pkgs.writeText "loader.conf" ''
            timeout 0
            editor no
          '';

          # A UKI is picked up from /EFI/Linux without a loader entry. Slot A only; the RAUC phase
          # adds the other slot's UKI here (and boot counting: `boot.uki.tries`).
          "/EFI/Linux/${config.system.boot.loader.ukiFile}".source =
            "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";
        };
        repartConfig = {
          Type = "esp";
          Format = "vfat";
          Label = label.esp;
          SizeMinBytes = "512M";
          SizeMaxBytes = "512M";
        };
      };

      "20-root-a" = {
        storePaths = [ config.system.build.toplevel ];
        repartConfig = (rootSlot "0e4e078e-d156-41d5-ab96-9095b6b0f5b7" label.rootA) // {
          Format = "ext4";
        };
      };

      # No Format and no contents: an empty partition of the same size, with a stable UUID so the
      # RAUC slot definition can name it from day one.
      "30-root-b".repartConfig = rootSlot "2c7bb7db-c0b6-4c5e-81c1-56d2f9596b21" label.rootB;

      "40-state".repartConfig = {
        Type = "linux-generic";
        Format = "ext4";
        Label = label.state;
        SizeMinBytes = "4G";
        SizeMaxBytes = "4G";
      };

      "50-data".repartConfig = dataPartition;
    };
  };

  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/${label.rootA}";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  # The hot-state partition is created and formatted by the image build (autoFormat stays off).
  recasanix.state.device = lib.mkDefault "/dev/disk/by-partlabel/${label.state}";

  boot = {
    # The image build places the boot loader itself (above); there is no installer to run on a
    # device that is only ever flashed.
    loader.systemd-boot.enable = lib.mkForce false;
    loader.grub.enable = false;

    # Grow the data partition to the disk it was flashed to: eMMC and NVMe sizes vary, the image
    # does not. Repart runs in the initrd on whichever disk backs the root filesystem (no device
    # name is baked in) and only touches the partition it has a definition for.
    initrd.systemd = {
      enable = true;
      repart.enable = true;
    };

    # Serial console next to the (usually absent) display: the first thing to reach on a headless
    # prototype, and how the image boot test (T6) watches it come up.
    kernelParams = [
      "console=tty0"
      "console=ttyS0,115200n8"
    ];
  };

  systemd.repart.partitions."50-data" = dataPartition;

  # ---------------------------------------------------------------------------------------------
  # NOT IMPLEMENTED — the two follow-ups this layout is prepared for (AGENTS.md §2):
  #
  #   * RAUC: a system.conf naming recasanix-root-a/-b as slots (by the UUIDs above), the systemd-boot
  #     bootloader backend, a UKI per slot on the ESP, and the signed .raucb bundle as a derivation.
  #   * dm-verity: nixos/modules/image/repart-verity-store.nix seals the root as a verity partition
  #     pair; it changes this layout (a hash partition per slot), so decide it together with RAUC.
  # ---------------------------------------------------------------------------------------------
}
