# Storage layer — design (2026-10-29)

Owner decisions 2026-10-29:

| # | Decision |
|---|---|
| U1, U2 | upstream: backend-neutral `/v2/storage` contract + CasaOS-UI Storage Manager PRs, **draft** until the owner has tested them |
| C1 | one pool (label), volumes = subvolume directories under `/DATA` |
| C4 | backends in the image: **btrfs + mdadm** |
| partitioning | advanced view only; default flows whole disks; system disk never; eMMC data partition = a slice |

Phase 6 "Storage layer" ([DEVELOPMENT.md](../DEVELOPMENT.md)), on top of `recasanix-storage`
([storage-manager.md](./storage-manager.md)). Goal: pools, members, volumes managed from the dashboard;
simple by default, powerful when asked; one model over several backends (btrfs now; mdadm, ZFS, LVM later).

## 1. Prior art

| Tool | Paradigm | Strong | Weak | Take |
|---|---|---|---|---|
| Synology DSM Storage Manager | pool-first: *storage pool* (RAID type) → *volume* → shared folders; wizards | intent-level choice (protection + capacity calculator), Repair / Add drive / Change RAID type, hot spare, scrub schedule; hides mdadm+LVM+btrfs | rigid; SHR magic opaque | **main UX model**: pool → volume, wizard, capacity/protection preview, Repair as one flow |
| TrueNAS (ZFS) | pool → vdev (layout) → disk; datasets on top | explicit topology, Replace/Offline/Online per disk, scrub tasks, alerts | ZFS-only words (vdev, dRAID); layout irreversible | per-disk actions in the topology; layout picker with width |
| QNAP Storage & Snapshots | RAID group → pool → thick/thin volumes | "replace disks one by one" to grow, RAID migration | three levels, confusing | migration as a guided flow |
| Unraid | slots: parity + data disks, each own fs; separate btrfs/zfs pools | assignment table is dead simple | non-standard parity, array stop/start | role assignment per disk as a table |
| Rockstor (btrfs NAS) | pools (btrfs profile) → shares (subvolumes) | Resize/ReRaid wizard: add/remove disks + profile change online (balance); [docs](https://rockstor.com/docs/interface/storage/pools-btrfs.html) | balance blocks other ops; defaults reasserted on non-standard profiles | **btrfs backend semantics**: reraid = balance convert, one exclusive op at a time |
| Cockpit storage (UDisks2) | device tree: every block device shows its content (partition table, fs, PV, md member, LUKS), contextual actions | universal, all Linux stacks; btrfs subvolumes since 309 ([309](https://cockpit-project.org/blog/cockpit-309.html)), Stratis | exposes Linux concepts; multi-device btrfs member management missing ([bz2352385](https://bugzilla.redhat.com/show_bug.cgi?id=2352385)) | **advanced view**: device → content tree |
| OpenMediaVault | function pages: Disks, SMART, RAID (mdadm), File systems; LVM/ZFS plugins | each step explicit | no integration, user composes layers | — (anti-pattern for us) |
| Proxmox VE | Disks → LVM / LVM-thin / Directory / ZFS create dialogs | one dialog per backend, disk checkboxes, RAID level | backend-first, not intent-first | disk multi-select + level in one dialog |
| GParted / KDE Partition Manager, GNOME Disks | partition map; GParted: pending-operation queue, "apply all" | visual, preview before writing | partitions only | **plan → preview → apply** |
| blivet (Anaconda) | device tree + formats + queued *actions* (create/destroy/resize/add-member), executed in dependency order ([intro](https://blivet.readthedocs.io/en/latest/intro.html)) | backend-neutral object model, nothing written until execute | Python, installer-oriented | **model**: device ≠ format (content); actions planned, then executed |
| curtin / Subiquity, disko (Nix) | declarative storage config (disk, partition, raid, lvm, format, mount) | reproducible, backend-neutral schema | install-time; disko = cold layer (pools are hot here, AGENTS §2) | schema vocabulary; **not** a runtime mechanism |
| Stratis | pool → filesystems, thin, no layout choice | simplest model | no redundancy | volumes without sizes |

Conclusions:
- **user layer**: pool-first, intent words (Synology/Rockstor): "protection: none / 1 disk / 2 disks", capacity shown
- **expert layer**: device tree + content (Cockpit) as a second view, not the default
- **engine**: blivet-like — model + planned actions, preview, apply; validated against a fresh listing at apply
- **per-disk actions in context** (TrueNAS): Replace, Remove, Add, Wipe on the disk where it is

## 2. Abstract model

| Object | Meaning | btrfs | mdadm (+fs) | ZFS | LVM |
|---|---|---|---|---|---|
| Disk | physical device, health (SMART), role | disk | disk | disk | disk |
| Slice | what a pool consumes: whole disk (default) or partition | device | md member (partition or disk) | vdev member | PV |
| Pool | redundancy group + capacity | filesystem (multi-device) | array | pool (vdevs) | VG (+ raid LVs) |
| Layout | `none` (concat/stripe) · `mirror(n)` · `parity(p)` | single/raid0 · raid1/raid1c3/c4 · (raid5/6: refused, unsafe) | linear/0 · 1 · 5/6 | stripe · mirror · raidz1/2/3 | linear · raid1 · raid5/6 |
| Volume | space for data on a pool, a folder for users/apps | subvolume (+ qgroup quota) | the fs on the array (one) | dataset (+ quota) | LV + fs |
| Job | long operation with progress | balance, replace, scrub | resync, recover, check | resilver, scrub | pvmove, sync |
| State | ok, degraded, rebuilding, checking, reshaping, inactive (`GET /v1/disks/raid`, done) | ✓ | ✓ (upstream) | map | map |

Verbs (backend declares support → UI shows only those):

| Verb | Object | btrfs | mdadm | ZFS | LVM |
|---|---|---|---|---|---|
| create pool (layout, disks) | Pool | mkfs.btrfs -d/-m | mdadm --create + mkfs | zpool create | vgcreate (+ lvcreate) |
| add disk (grow) | Pool | device add (+ balance) | --add + --grow | add vdev (whole vdev) | vgextend |
| replace disk | Pool member | replace start | --add, --fail/--remove | zpool replace | pvmove |
| remove disk (shrink) | Pool member | device remove | --grow fewer (limited) | remove (limited) | pvmove + vgreduce |
| change layout | Pool | balance convert (online) | --grow --level (limited) | ✗ | lvconvert |
| check (scrub) | Pool | scrub | check | scrub | lvchange --syncaction |
| mount degraded | Pool | -o degraded | --run | (import) | --activationmode degraded |
| create / remove volume, quota | Volume | subvolume, qgroup | ✗ (one) | dataset, quota | lvcreate/lvremove |
| wipe disk | Disk | wipefs | --zero-superblock + wipefs | labelclear + wipefs | pvremove + wipefs |
| partition (advanced) | Disk | sgdisk | sgdisk | (whole disk) | sgdisk |

Plan → preview → apply:
- request = intent (`{verb, pool, layout, disks}`) → server computes a **Plan**: steps (abstract + exact
  argument vectors), effects (capacity before/after, failures tolerated, **disks erased**, data at risk, online
  or not, est. duration), refusals with reason
- apply = plan id + typed confirmation (disk names, as upstream's RAID add) → **re-validated against a fresh
  listing** (current rule); stale plan → 409
- long steps → Job; progress surfaces in `GET /v1/disks/raid` (already) + a jobs list; one exclusive job per pool
- every destructive verb: test proving nothing changes until asked correctly (current rule)

## 3. UX

Default (simple):
- **Storage** tab: pool cards — name, layout in words ("Mirror — survives 1 disk failure"), capacity bar,
  state tag, Jobs progress; actions: Add disk, Change protection, Check now, (Repair when degraded)
- **Drives** tab: each disk with role ("in pool data", "spare", "free", "system"), health; contextual actions:
  free → "Add to pool…" / "Create pool…"; failed/missing member → "Replace…"; member → "Remove from pool…";
  free with old content → "Wipe…"
- **Create pool** wizard: pick free disks (multi-select) → pick protection (only layouts possible with that
  count; capacity calculator per option) → preview (Plan effects, erased disks listed) → type to confirm
- **Repair**: degraded pool → "Replace <missing>" → pick a free disk ≥ size → preview → confirm → rebuild progress
Advanced (expert toggle): device → content tree (Cockpit), partitioning, mixed-size layouts, raw profile names

## 4. Hot / cold split

| Item | Side | Status |
|---|---|---|
| pool topology, members, layout, volumes, quotas | hot (runtime, recorded by the fs itself) | fits AGENTS §2 |
| backend tooling, kernel modules, udev rules (btrfs-progs; mdadm, zfs, lvm2 if enabled) | cold (image) | which backends ship = **decision C4** |
| mounting the pool | cold today: one pool, label `recasanix-data`, NixOS `fileSystems` + automount | fits for one pool |
| mounting **more pools / volumes as mounts** | — | **conflict C1** |
| degraded mount at boot | cold today (none: a mirror missing a disk does not mount) | runtime "Mount degraded" verb = hot, fits (AGENTS: explicit operation) |
| scrub schedule | cold today (`services.btrfs.autoScrub`) | user schedule = **conflict C3** |
| Docker data-root, `/DATA`, casaos paths on the pool | cold | pool replace/destroy must keep the label → fine; destroy pool = **C5** |
| the image's blank data partition on the eMMC | hot (offer it as a slice) | fits; partitioning the system disk otherwise: refused |

Conflicts, options:
- **C1 more than one pool, or volumes as mount points**
  - a) one pool by convention (label), volumes = subvolumes as directories under `/DATA` (no new mounts) — no conflict
  - b) many pools: Nix ships a generic mechanism (systemd generator or udev rule) that mounts every btrfs
    labelled `recasanix-pool-*` under `/var/lib/recasanix/pools/<name>`; the set of pools stays hot
    (filesystem labels), the mechanism cold — "baseline + include" pattern, no fstab edits
  - c) runtime transient mount units from the service (`systemd-run`/`/run`) — hot mounts; boot order with docker unclear
  - recommend: **a now, b when a second pool is needed**
- **C3 scrub schedule**: a) fixed by Nix (monthly) b) Nix timer reading a hot setting file on the state partition;
  recommend **a** now (+ "Check now" verb)
- **C4 backends in the image**: btrfs only (now) vs + mdadm / ZFS / LVM; each costs closure + boot code
  (mdadm assembly, ZFS import needs pool list → `zpool.cache` on state = hot data, cold mechanism)
- **C5 destroying the pool**: cold units depend on it (docker data-root, casaos data); a) refuse while
  apps/data exist b) stop dependents + wipe; recommend **a**

## 5. Where the code goes

- engine + backends: `recasanix-storage` (ours), argument vectors only, plan/apply as above
- API: the UI's current contract (LocalStorage v1 + `/v1/disks/raid`) stays; new verbs need a contract —
  **decision U1**: a backend-neutral `/v2/storage` (pools, members, volumes, plans, jobs) proposed upstream
  (LocalStorage could implement it for md) vs our own namespace
- UI: **decision U2**: upstream CasaOS-UI PRs (Storage Manager panel grows: wizard, drive roles) vs a local patch

## 6. As built (I1, I2)

- `/v2/storage`: `GET` (pool, drives, layouts, jobs) · `GET /layouts?disks=` · `POST /plans` · `POST /plans/{id}/apply` · `GET /jobs`
- one job at a time; plan kept 10 min; apply re-plans and compares the commands (stale → 409)
- verbs per pool / drive in the view; refusals say why (409 + message)
- confirmation typed: disks erased (their names), less protection (pool name), mount degraded (pool name)
- md: array `/dev/md/<label>` (`--name=<label>`), btrfs `-d single -m dup` on it; grow waits for the reshape, then `btrfs filesystem resize max`
- mount degraded: btrfs = stop the automount unit + `mount -o degraded`; md = `mdadm --run`; until next boot
- btrfs mounted degraded writes new data with one copy (`single`): replacing a missing / failed member waits
  for the replace, then soft-converts (`balance -dconvert=<p>,soft`); a pool with data outside its layout and
  no operation running = `degraded`, tolerates 0, `problem` text, verb `restore-layout` (`/v1/disks/raid` keeps
  `ok`: every disk is there)
- md under the storage manager's sandbox: personalities loaded at boot (`raid1`, `raid456`: `ProtectKernelModules`),
  `/run/mdadm` writable (its map)
- a failed command's last stderr lines are in the job's `error` and the log
- v1 `POST /v1/storage` (Create Storage): unchanged for btrfs; refused (409) on a parity pool
- not yet: partitioning (advanced view), volumes (I3), replace onto a larger disk → resize, md layout change, upstream LocalStorage implementation (md)
- server texts (summary, steps, notes, refusals): English only; UI chrome: en_US, fr_FR

## 7. Increments

| # | Content | Needs |
|---|---|---|
| I0 | RAID state + alerts (done: `GET /v1/disks/raid`, fork `feat/raid-alerts-any-backend`, T11, T17) | — |
| I1 | **done** — engine (`layout.go`, `pools.go`, `plan.go`, `api_v2.go`): btrfs (none, mirror 2/3) + md (parity 1/2, btrfs on top); verbs create, add, replace, remove, change layout (btrfs), restore layout, check / stop, mount degraded, wipe; T18 | — |
| I2 | **done (draft)** — CasaOS-UI#69 `feat/storage-pools` (Pool tab, plan dialog), in staging; contract: CasaOS-LocalStorage#10 `feat/storage-layer-api` (`api/storage/openapi.yaml`); T11 phase `layer` | owner tests → PRs out of draft |
| I3 | volumes (subvolumes) + shares/apps integration, quotas | C1 a |
| I4 | further backends (mdadm, ZFS) | C4 |
