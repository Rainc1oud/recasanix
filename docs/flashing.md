# Flashing the ReCasaNix image

`nix build .#image` produces a directory holding one raw GPT disk image, `recasanix_<version>.raw`. This
page covers getting it onto the board's eMMC and reaching the result. The image is a **prototype**: it
has been booted only under QEMU/OVMF (check `image-boots`, T6), never on the N200 board.

## 1. Let yourself in first

The image has no password and root cannot log in: SSH is key-only, and the keys come from
`nix/hosts/admin-authorized-keys` — an empty template in the repository. Without a key the flashed device cannot be
reached (there is a serial login prompt, but nobody has a password to type).

```sh
cat ~/.ssh/id_ed25519.pub >> nix/hosts/admin-authorized-keys
```

Keep the key in your working copy only. The file is tracked (as the empty template), so Nix reads
your local content; the pre-commit hook installed by the dev shell refuses to commit a key, and CI
rejects a pushed one.

## 2. Build

```sh
nix build .#image
ls -lsh result/          # ~2.6G on disk; the file is *sparse*, its apparent size is ~22G
```

## 3. Write it to the eMMC

Boot the board from a USB stick with any Linux, identify the eMMC (`lsblk`, usually `/dev/mmcblk0`),
and write the image. The file is mostly holes, so compress it if it has to cross a network:

```sh
# from the build machine, to a live system on the board
zstd -T0 -c result/recasanix_*.raw | ssh root@<board> 'zstd -d | dd of=/dev/mmcblk0 bs=4M conv=fsync status=progress'

# or, with the image on the board already
dd if=recasanix_0.1.0.raw of=/dev/mmcblk0 bs=4M conv=fsync status=progress
```

Write **every** block: do not use `conv=sparse`. It skips the zero runs instead of writing them, so on
a disk that has been used before, the old contents survive in exactly the places the image says are
empty — `recasanix-root-b` above all, which must start blank. **Double-check the target device**; `dd`
will not ask.

The image does not need to fit the disk exactly: it is smaller than a 32 GB eMMC, and on first boot the
data partition grows to the end of whatever disk it was flashed to.

## 4. Firmware (UEFI) settings

- Boot mode **UEFI**, not legacy/CSM. Boot the eMMC's `EFI/BOOT/BOOTX64.EFI` (systemd-boot); if the
  board does not list it, add it as a boot entry by hand.
- **Secure Boot off** — the boot loader and kernel are not signed yet.
- Hold a key (space) while systemd-boot starts to reach its menu; by default it boots at once and
  does not allow editing the kernel command line.

## 5. Console and login

- **Serial:** `console=ttyS0,115200n8` is on the kernel command line next to the display. The
  board's serial header pinout is not known yet (TODO in `nix/modules/hardware-n200.nix`).
- **SSH:** `ssh admin@<address>`; the device takes its address by DHCP on the Ethernet port.
  The web UI is on port 80.
- **First run:** create the UI administrator once, on the device, as `admin`:
  `sudo recasanix-user-admin bootstrap`.

## 6. Storage

The image reserves a blank partition, `recasanix-data`, for the data pool. Nothing is formatted for you —
pools are created at runtime. (The UI's storage manager lists disks and pools but is read-only for now; it
refuses to create one, see [storage-manager.md](./storage-manager.md).) For the single-disk case on the eMMC:

```sh
sudo mkfs.btrfs -L recasanix-data /dev/disk/by-partlabel/recasanix-data
sudo mkdir -p /var/lib/recasanix/data/DATA          # mounts the pool on first access
sudo systemctl start DATA.mount docker
sudo systemctl restart casaos casaos-app-management
```

For NVMe or SATA disks, or a two-disk mirror, see the reference commands at the top of
`nix/modules/storage.nix`. The pool is found by its filesystem label, `recasanix-data`.

## Partition layout

| # | GPT name | Size | Purpose |
|---|---|---|---|
| 1 | `recasa-esp` | 512 MiB | boot loader and kernel |
| 2 | `recasanix-root-a` | 8 GiB | the running system |
| 3 | `recasanix-root-b` | 8 GiB | empty; reserved for the first over-the-air update |
| 4 | `recasanix-state` | 4 GiB | accounts, ReCasaOS data, SSH host keys — survives updates |
| 5 | `recasanix-data` | rest of the disk | blank; grown on first boot |

There is no update mechanism yet: `root-b` sits unused until the RAUC phase.
