# Task 4.1 — the development VM's hardware profile. Everything lives under `virtualisation.vmVariant`,
# so it shapes only `system.build.vm` (the runner) and leaves the closure that becomes the hardware
# image untouched.
{ lib, ... }:
{
  virtualisation.vmVariant = {
    # With a boot loader (UEFI) the runner no longer appends console= itself: put the serial
    # console on the kernel command line (last one is the primary) and skip the boot menu wait.
    boot.kernelParams = [
      "console=tty0"
      "console=ttyS0,115200n8"
      # The root disk is disposable (the runner recreates it), so let the initrd's fsck repair a damaged
      # root filesystem instead of stopping in the (locked) emergency shell.
      "fsck.repair=yes"
    ];
    boot.loader.timeout = 0;

    recasanix.state = {
      device = "/dev/disk/by-id/virtio-recasanix-state";
      autoFormat = true;
    };

    # Development convenience only (this block never reaches the hardware image): let the well-known
    # console password also work over ssh, so `ssh -p 2222 admin@localhost` needs no key setup.
    services.openssh.settings.PasswordAuthentication = lib.mkForce true;

    # What the VM runner prints on the host is wiped a moment later, when the UEFI firmware clears the
    # terminal — so the same hints are shown here, once you have logged in (console or ssh).
    users.motd = ''

      ReCasaNix development VM

        web UI, from the host   http://localhost:8080          ssh -p 2222 admin@localhost
        first run               sudo recasanix-user-admin bootstrap     (creates the UI administrator)

        Apps need a data pool. The UI's storage manager is read-only for now (it lists, it does not
        create), so make the pool by hand on the blank disk /dev/vdb:

          sudo mkfs.btrfs -L recasanix-data /dev/vdb
          sudo mkdir -p /var/lib/recasanix/data/DATA
          sudo systemctl start DATA.mount docker
          sudo systemctl restart casaos casaos-app-management

    '';

    virtualisation = {
      memorySize = 4096; # MB — the product's RAM baseline
      cores = 4;
      useEFIBoot = true; # UEFI (OVMF) + systemd-boot, like the hardware
      useBootLoader = true;

      # The hot-state disk (accounts, ReCasaOS data and config, SSH host keys): a persistent image the
      # runner creates and that outlives rebuilds of the VM, like the `state` partition of the hardware
      # image. autoFormat creates its ext4 filesystem on the first boot.
      qemu.drives = lib.mkAfter [
        # The data disk first, so it is /dev/vdb: 8 GiB, persistent like a NAS's data disk (the runner
        # creates it next to the state disk; `--fresh-data` blanks it). Nothing is created on it — make
        # the pool from the UI or by hand (see modules/storage.nix).
        {
          name = "recasanix-data";
          file = ''"$RECASANIX_DATA_IMAGE"'';
          deviceExtraOpts.serial = "recasanix-data";
        }
        {
          name = "recasanix-state";
          file = ''"$RECASANIX_STATE_IMAGE"'';
          deviceExtraOpts.serial = "recasanix-state";
        }
      ];

      # A mirror is covered by the storage check (T3), which has its own machines; add a second data
      # drive above (and create it in nix/vm-runner.nix) to try one in the dev VM.

      # Headless by default: serial console on stdio, so an agent (or a plain terminal) can drive it.
      graphics = false;

      # host → guest:  8080 → 80 (web UI),  2222 → 22 (ssh)
      forwardPorts = [
        {
          from = "host";
          host.port = 8080;
          guest.port = 80;
        }
        {
          from = "host";
          host.port = 2222;
          guest.port = 22;
        }
      ];
    };
  };
}
