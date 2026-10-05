# Testing — quick start

Commands to bring up the VM, run the tests, build the hardware image, test it under emulation and flash
it. Run everything from the repository root.

**You need:** Nix with flakes enabled, an `x86_64-linux` machine, and `/dev/kvm` (the VM tests and the
image test are virtual machines). `nix develop` gives a shell with the extra tools used below (`qemu`,
`sfdisk`, `zstd`, `jq`).

New files must be `git add`ed before Nix sees them.

## 1. Bring up the VM

```sh
nix run .#vm
```

The console is on your terminal; quit QEMU with `Ctrl-A x`. Then:

| | |
|---|---|
| Web UI | <http://localhost:8080> |
| SSH | `ssh -p 2222 admin@localhost` — password `recasanix` (development only) |
| First run | in the VM: `sudo recasanix-user-admin bootstrap` — creates the UI administrator, then log in to the UI |
| Data disk | `/dev/vdb`, blank — apps need a pool on it, see below |
| Reset | `nix run .#vm -- --fresh` resets the root disk; `rm -rf ~/.local/state/recasanix-vm/<checkout>-<hash>` (shown in the banner) gives a factory-fresh VM. Each clone has its own disks. |

Anything the runner prints on your terminal is wiped a moment later, when the UEFI firmware clears the
screen. The same hints are shown when you log in (the message of the day), and are repeated here.

**Make a data pool.** The gear on the UI's storage widget opens a manager that can now create one: log in,
open Storage, *Create Storage*, pick `/dev/vdb`, *Format and create*. That is the same thing the shell
commands below do — formatting or removing an *existing* storage is what remains refused
([docs/storage-manager.md](./docs/storage-manager.md)). By hand, inside the VM:

```sh
sudo mkfs.btrfs -L recasanix-data /dev/vdb
sudo mkdir -p /var/lib/recasanix/data/DATA        # this mounts the pool on first access
sudo systemctl start DATA.mount docker
sudo systemctl restart casaos casaos-app-management
```

The port forwards listen on **all** host interfaces. To reach the VM from another machine, open the
host firewall for 8080 — and keep in mind that the VM has a well-known password.

## 2. Run the tests

```sh
nix flake check -L          # everything (includes the image test, which builds the image)
```

One check at a time:

```sh
nix build .#checks.x86_64-linux.<name> -L
```

| `<name>` | What it covers |
|---|---|
| `lint` | `nixfmt --check`, `statix`, `deadnix` |
| `pin-drift` | the ReCasaOS pins agree with upstream's `components.lock.json` |
| `no-host-management` | no installer/self-update/package-manager machinery in the closure |
| `unit-casaos`, `unit-casaos-gateway`, `unit-casaos-message-bus`, `unit-casaos-user-service`, `unit-casaos-app-management`, `unit-recasanix-storage` | each component's own Go tests (the last is our own storage manager) |
| `recasaos-boot` | VM test: all services up, the UI is served, login is enforced |
| `ui-login` | VM test: headless Chromium logs into the real UI and stays logged in |
| `storage` | VM test: single-disk and mirrored pools, boot without disks |
| `state-persistence` | VM test: hot state survives a reboot and a replaced root disk (what an image update does) |
| `docker`, `app-lifecycle` | VM tests: the container runtime, installing an app |
| `storage-manager` | VM test: the storage manager lists disks and volumes, creates storage on a blank disk (through the real UI, and via the API to extend it), refuses changes to an existing one, needs a real access token |
| `image-boots` | boots the real hardware image (section 4) |

Debug a VM test interactively (a Python prompt with the machine: `start_all()`, `machine.shell_interact()`):

```sh
nix run .#checks.x86_64-linux.recasaos-boot.driverInteractive
```

Format the tree with `nix fmt`.

## 3. Build the hardware image

Give yourself a way in first — the image has no password, and SSH is key-only:

```sh
cat ~/.ssh/id_ed25519.pub >> nix/hosts/admin-authorized-keys   # working copy only: never commit it
```

```sh
nix build .#image
ls -lsh result/                                   # recasanix_<version>.raw: ~2.6G on disk, ~22G apparent (sparse)
sfdisk -J result/*.raw | jq -r '.partitiontable.partitions[] | "\(.name)  \(.size * 512 / 1048576) MiB"'
```

Five partitions: `recasa-esp`, `recasanix-root-a`, `recasanix-root-b` (empty), `recasanix-state`, `recasanix-data`.

## 4. Test the image under emulation

**Automated** — boots the image exactly as it would be flashed (UEFI, NVMe disk, Intel NIC) and checks
the layout, the first-boot growth of the data partition and where hot state lands:

```sh
nix build .#checks.x86_64-linux.image-boots -L
```

A pass is the exit status; `result/` then holds the evidence: `summary.txt`, `serial.log` (the console of
the boot that was checked) and `partition-table.json` (the table as the guest left it, with the grown
data partition). Most other checks (`lint`, `no-host-management`, …) are pass/fail only and leave an empty
file as their result: the exit status is the answer, and `-L` shows the log.

**By hand** — the same image on a scratch copy, with your terminal as the serial console:

```sh
nix run .#emulate-image
```

| | |
|---|---|
| Web UI | <http://localhost:8081> (up in well under a minute) |
| SSH | `ssh -p 2223 admin@localhost` — key-only, see below |
| Quit | `Ctrl-A x` |
| Fresh first boot | `nix run .#emulate-image -- --fresh` (this passes `--fresh` to the script) |

Both forwards listen on loopback only. What it does, and what it insists on:

- The image in the Nix store is read-only, so it is copied (sparse: about 2.6 GiB is really written) to
  `/tmp/recasanix-image` and enlarged to a 32 GiB disk, like flashing it to a bigger eMMC. The disk and the
  firmware's variable store are kept between runs, so hot state persists; they are recreated when the
  image changes or with `--fresh`.
- It **refuses to start** if the filesystem does not have enough free space: the copy plus 4 GiB of
  headroom. On many systems `/tmp` is a tmpfs, so the disk then lives in RAM (the script says so); point
  it at a real disk with `RECASANIX_IMAGE_DIR=/var/tmp/recasanix-image`.
- It attaches a blank 8 GiB **SATA data disk** (a sparse file, `data1.raw`, next to the system disk), like the
  board's data slots: the image has no pool, and making one needs a disk. It persists like the system disk.
  `RECASANIX_DATA_DISKS=2` adds a second, `0` none.
- It needs KVM, and stops with a message if `/dev/kvm` is not usable.

`RECASANIX_IMAGE_DIR`, `RECASANIX_DISK_SIZE`, `RECASANIX_DATA_DISKS`, `RECASANIX_DATA_DISK_SIZE`, `RECASANIX_HEADROOM_GIB`, `RECASANIX_UI_PORT`, `RECASANIX_SSH_PORT`,
`RECASANIX_BIND`, `RECASANIX_MEM_MB` and `RECASANIX_CPUS` change the defaults; `nix run .#emulate-image -- --help`
lists them. Arguments after a second `--` go to QEMU.

The image has no password, so there is no console login: put your key in `nix/hosts/admin-authorized-keys`
(section 3) and rebuild. Then:

```sh
ssh -p 2223 admin@localhost
sudo recasanix-user-admin bootstrap        # creates the UI administrator (prompts for name and password)
```

Then make the data pool on the data disk, by hand for now (see the VM section for why). Use the `by-id`
name: the kernel's `sda`/`sdb` order is not stable, and with more than one data disk it is not the order
of the numbers.

```sh
sudo mkfs.btrfs -L recasanix-data /dev/disk/by-id/ata-QEMU_HARDDISK_recasanix-data1
sudo mkdir -p /var/lib/recasanix/data/DATA
sudo systemctl start DATA.mount docker
sudo systemctl restart casaos casaos-app-management
```

`nix build .#image` prints a warning if no key is configured. (The emulator's own start-up banner is
wiped by the firmware, like the VM's, so do not rely on it.)

## 5. Flash it

Boot the board from a USB stick with any Linux, find the eMMC (`lsblk`, usually `/dev/mmcblk0`) and write
the image. **Double-check the target: `dd` does not ask.**

```sh
# from the build machine, to the live system on the board
zstd -T0 -c result/recasanix_*.raw | ssh root@<board> 'zstd -d | dd of=/dev/mmcblk0 bs=4M conv=fsync status=progress'
```

Do **not** use `conv=sparse`: it skips the zero runs instead of writing them, leaving old data in the
places the image says are empty (`recasanix-root-b` above all). Then set the firmware to UEFI with Secure
Boot off and boot from the eMMC. The data partition grows to the disk on first boot.

Firmware settings, first login, creating the data pool and the partition layout are in
[docs/flashing.md](./docs/flashing.md). The image has only been booted under emulation so far, never on
the board.
