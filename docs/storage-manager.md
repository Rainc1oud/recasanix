# The storage manager (`recasanix-storage`)

The web UI has a **Storage** widget with a gear. The gear opens the *storage manager*: the disks, the
volumes on them, and buttons to create, format and remove storage. The pinned ReCasaOS has no service
behind those buttons (they belonged to CasaOS-LocalStorage, which it does not ship), so the panel was
defunct. `recasanix-storage` is ReCasaNix's own small service that answers the same routes.

**It can now create storage.** A blank disk (`avail` in `/v1/disks`) can be turned into the data pool, or
added to it, through the UI or the API — the same operation the manual `mkfs.btrfs` steps in
[TESTING.md](../TESTING.md) describe, automated. Formatting or removing an *existing* storage, and
merging storages, remain refused with a message that says so.

| | |
|---|---|
| Source | `services/recasanix-storage/` — Go, standard library plus one JWT library, no cgo |
| Package / unit | `pkgs.recasanix-storage`; `services.recasaos.storage` (on by default), unit `recasanix-storage.service` |
| Tests | `checks.<sys>.unit-recasanix-storage`, `checks.<sys>.storage-manager` (T11: real VM, real gateway, real UI in a browser) |
| Licence | Our own code, AGPL-3.0-or-later ([AGENTS.md](../AGENTS.md) §2) |

## What the user sees

- **Storage tab**: every mounted volume — the system volume tagged "OS", and the data pool with its label,
  filesystem and free space. The system volume is named by its filesystem label.
- **Drive tab**: every physical disk with its model, size, health and temperature.
- **Create Storage** offers the disks that are blank, unused and at least 1 GiB (`minDiskSize`).
  Choosing one and pressing *Format and create* **formats it and brings the pool online**: a success
  toast, and the panel refreshes to show it. Pressing **Format** or **Remove** on an *existing* storage,
  or *Merge Storages*, is refused with a message that says those are not available yet.

## Why not upstream's CasaOS-LocalStorage

Assessed 2026-09 against `IceWhaleTech/CasaOS-LocalStorage` (Apache-2.0, Go). Nothing in ReCasaOS says why
it is absent: its component table lists only the root service, gateway, user service, message bus,
app management and the UI, and calls everything else "other `casaos-*` daemons … separate release gates".
There is no fork. The reasons *not* to adopt it are in the code:

- **It is three products in one binary.** Disk listing (`lsblk`, `smartctl`, `df`: the useful part, about a
  thousand lines), a disk lifecycle (`parted`/`sfdisk`, **`mkfs.ext4` only**, mount, USB automount), and
  cloud drives (rclone 1.62.2, Google Drive/Dropbox/OneDrive with OAuth, FUSE, a half-removed mergerfs).
  ReCasaOS's root service deliberately disabled the cloud part.
- **It is the host-management pattern the guardrail forbids** ([DEVELOPMENT.md](../DEVELOPMENT.md)): it
  edits `/etc/fstab` (generated on NixOS), runs `systemctl enable/disable devmon`, needs `udevil`, and ships
  Debian/Ubuntu/Arch setup and cleanup scripts.
- **It runs as root and puts request data in a shell.** `DELETE /v1/disks/usb` takes `mount_point` from the
  body, checks only that the path exists, and concatenates it into `/bin/bash -c "source …; UDEVILUmount
  <path>"`. (From reading the code; not exercised. It appears reachable by an authenticated caller who can
  create a directory with shell metacharacters in its name.)
- **It has none of what the product needs**: no btrfs, no mirror, replace, degraded handling or scrub.
- **It is stale**: Go 1.21, CasaOS-Common 0.4.9 (the fork pins 0.4.11), last real change Aug 2024.
  `govulncheck` was not run on it.

What *is* worth taking is its **API contract**, because the UI was written against it. This service
implements the same routes and shapes from scratch, so the UI needed no change beyond one bug fix (below).
Creating storage is likewise built from scratch here — no partitioning, no shelling command strings, and
every write re-validates its target against a fresh disk listing rather than the ext4-only, path-trusting
approach above.

## The contract

Everything is behind authentication. Routes below `/v1/disks`, `/v1/storage` and `/v2/local_storage` are
registered with the gateway.

| Request | Answer |
|---|---|
| `GET /v1/disks` | `{success, message, data: {disks: [Drive], avail: [Drive]}}` — `avail` are disks that could be turned into storage right now: blank, unused, at least `minDiskSize` |
| `GET /v1/storage[?system=show]` | `{…, data: [{disk_name, size, path, type, children: [Volume]}]}` — the system disk only with `?system=show` |
| `POST /v1/storage` `{path, format:true}` | Formats `path` (or adds it to the pool if one already exists) and brings it online. `200` on success; `409` if `path` is not currently eligible; `501` if `format` is `false` (mounting an existing filesystem instead of formatting is not supported) |
| `PUT /v1/storage`, `DELETE /v1/storage` | **501** — formatting or removing an existing storage is not supported yet |
| `GET /v1/disks/usb` | `data: []` — removable media is not supported yet |
| `GET /v2/local_storage/merge` | `{message, data: []}` — nothing is merged (the v2 format has no `success`) |
| any other `GET` below those prefixes | 404 |
| any other method below those prefixes | **501**, with a message naming what is not supported |

`Drive`: `name, size, model, health, temperature, disk_type, need_format, serial, path, children_number,
children[{name,size,format,supported}], supported`. `Volume`: `uuid, mount_point, size, avail, used, type, path,
drive_name, label, persisted_in` — **the sizes are strings**, as the UI has always received them.
`POST /v1/storage`'s `name` field is accepted and **ignored**: there is one pool, under a fixed label, not
a per-disk name a user picks (see "Creating storage" below).

Mapping decisions:

- Disks are what a user would call one: not loop, RAM, network or zero-size devices.
- The system disk is the one with `/` on it; it is named `System`, as the UI expects.
- A volume mounted several times (a NixOS root also mounted at `/nix/store`, a pool bind-mounted at `/DATA`)
  is presented at **the data root if it is mounted there, otherwise at the shortest path**.
- Not storage, and never listed: the boot partition (`/boot…`), swap, and the hot-state filesystem
  (`recasanix.state` tells the service which mount it is).
- A **multi-device btrfs is listed once**, and *all* its members count as in use. `lsblk` reports the mount
  point on one member only; without this the second member of a live mirror was offered as "available"
  (found by T11, not by the unit tests).
- **`avail` requires the disk to be blank** (`children_number == 0` and no filesystem) as well as unmounted
  and above `minDiskSize` (1 GiB by default). A disk that already holds an unmounted filesystem or partition
  table is shown on the Drive tab but never offered for creating storage — the deliberately more
  conservative reading of "unpartitioned devices" than upstream's mount-only check.
- `persisted_in` is `fstab` when a mount is declared in `/etc/fstab` (NixOS writes it from `fileSystems`),
  else `none`.
- `health` is the UI's truthiness flag: SMART "failed" is the empty string (the UI shows *Damage*), anything
  else — including "SMART does not answer", which virtual disks do — is non-empty (*Healthy*). `temperature`
  is `0` (the UI shows *N/A*) when unknown. SMART is asked at most once per five minutes per disk.

## Creating storage

There is **one** pool, labelled `recasanix.storage.poolLabel` ("recasanix-data") — the appliance's convention,
not a user choice. `POST /v1/storage` formats the given disk directly, whole-disk, no partition table
(matching the manual instructions); if a device already carries the pool's label it instead runs
`btrfs device add`, extending the same filesystem. Either way, the request is only ever a single disk
path — chosen from the currently `avail` list — never a user-supplied filesystem label, mount point, or
option string.

**JBOD by default.** Adding a disk uses btrfs's ordinary "single" allocation profile: capacity is
additive, no redundancy. There is no UI flow for asking for a mirror instead (the create dialog is
one-disk-at-a-time); a mirror is still possible by hand (`mkfs.btrfs -d raid1 -m raid1`, see TESTING.md),
just not through the service.

Steps, run as plain argument vectors (no shell), matching the documented manual procedure exactly:

1. `mkfs.btrfs -f -L recasanix-data -- <disk>` (new pool) or `btrfs device add -f -- <disk> <pool mount>`
   (extending one).
2. `udevadm settle` — a fresh filesystem's `/dev/disk/by-label/recasanix-data` symlink needs a moment.
3. `mkdir -p -- <pool mount>/DATA` — this is what triggers the pool's systemd automount (it doesn't
   already exist, since the disk was blank a moment ago).
4. `mountpoint -q -- <pool mount>` — confirms the automount actually happened, rather than silently
   leaving `mkdir` to land on the un-mounted root filesystem.
5. `systemctl start -- DATA.mount docker.service`, then `systemctl restart -- casaos.service
   casaos-app-management.service` (they hold handles on the pre-mount `/DATA` and need to pick up the
   real one).

**Validation happens once, server-side, against a live listing — not against anything the client sent.**
`POST /v1/storage` re-lists disks on every call and only proceeds if the requested path is an *exact*
match in the freshly computed `avail` set. A made-up path, a partition instead of a disk, the system disk,
an already-mounted disk, one that already holds a filesystem, or one below the size threshold are all
rejected before anything runs — the request never reaches a command with an unvalidated path. Re-running
create on a disk that is already part of the pool is likewise rejected, so it can't be reformatted by
mistake (T11 checks the pool's UUID is unchanged after such an attempt).

## Security

- **Same rules as the ReCasaOS root service**: `Authorization: Bearer <ES256 JWT>` only (never a query
  string), verified against the key the user service publishes as JWKS; the token must expire and the issuer
  must be `casaos` (a **refresh token is refused**); no other algorithm. **No loopback exemption**: it
  listens on loopback, but any local process can reach that, and "from localhost" is not an identity.
  Failing to get the key fails closed. All failures give one identical 401.
- **Every argument to every command is either a fixed literal or the one disk path the eligibility check
  already approved.** There is no user-chosen label, mount point or option string anywhere in the command
  lines above — see "Creating storage".
- **Gateway registration** uses the gateway's per-boot service token (`gateway.token`, owner-only), read
  again on every call, and only ever sent to a loopback management address; redirects are not followed.
  Service-owned routes are not persisted and do not expire, so the service checks every 30 s and registers
  again if the gateway restarted and forgot them (T11 restarts the gateway to prove it).
- **The unit** runs as root (the token file is owner-only, and formatting a disk needs raw access) with
  `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, kernel/clock/hostname/control-group
  protections, namespaces, real-time and SUID restricted, `MemoryDenyWriteExecute`, address families limited
  to unix and inet, and a capability bounding set of `CAP_DAC_READ_SEARCH` (look at every mount point),
  `CAP_SYS_RAWIO` and `CAP_SYS_ADMIN` (`smartctl`, mounting).

## Known limits

- **Format, Remove and Merge on an *existing* storage are not implemented** (501). They are what the
  storage layer will add, on these same routes.
- **A mirror shows as "Single storage drive"** and under its first member disk: that wording and shape are
  the UI's. Both members appear on the Drive tab and neither is offered as available.
- **Health can read "Healthy" when it is really unknown** (see above), and virtual disks have no model, so
  the Drive tab shows ", 512 MB HDD". Real disks answer SMART and have models.
- **The image's blank `recasanix-data` partition is not offered.** It sits on the system disk (the eMMC), and
  the system disk is never listed as available, as in upstream. Once the manager can create pools, a
  single-disk machine needs exactly that partition to be offered — a case for the storage layer, not this
  release. (A pool that *is* made on it shows up, under the System disk, with `?system=show`.)
- **Removable media**: none listed, none mounted (it comes back as native units later, not scripts).
- **The UI patch**: upstream's create handler ends in `.finaly(…)`, a typo that left the panel on "Creation in
  progress" forever after any failed create — the first bug this surfaced under, since every create used to
  fail. `nix/pkgs/casaos-ui/patches/0004-storage-panel-finally-typo.patch` fixes it (material for the
  ReCasaOS maintainer).
- **Not verified**: how the UI displays the refusal for **Format** and **Remove** specifically (only
  *Create* is driven in a browser); a real disk's SMART data (virtual disks do not answer); a spun-down HDD
  (`--nocheck=standby` is there so as not to wake it, untested); real hardware.

## From here to the storage layer

The plan ([DEVELOPMENT.md](../DEVELOPMENT.md), Phase 6, "Storage layer") is a full manager on these routes:
extend, repair and replace a pool (`degraded` as an explicit operation, a mirror as a real UI choice, not
just JBOD), surface SMART and scrub state, format/remove an existing storage, removable media. What this
release already provides:

- the **contract** — routes, shapes, the UI's quirks, all verified against the real UI;
- **creating storage itself**, matching the manual procedure exactly;
- the **auth and registration** machinery, and the unit's sandbox;
- the **test harness**: a VM with blank disks, the real gateway and user service, a browser on the panel.

What the layer adds has to keep the rules above: argument vectors only, no `fstab` edits and no unit
enable/disable (Nix owns those), no data from a request in a path or a label without validation, and every
destructive operation covered by a test that proves it changes nothing until asked correctly.

## Running the tests

```sh
nix build .#checks.x86_64-linux.unit-recasanix-storage -L      # the unit tests
nix build .#checks.x86_64-linux.storage-manager -L           # the VM test, including creating storage via the real UI
```

`cd services/recasanix-storage && go test ./...` works in the dev shell (`-race` needs `CGO_ENABLED=1`).
