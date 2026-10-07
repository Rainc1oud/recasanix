# AGENTS.md — ReCasaNix

Orientation for coding agents working in this repository. Read this before touching the flake.
The executable task list lives in [DEVELOPMENT.md](./DEVELOPMENT.md); product rationale is in
[README.md](./README.md) and [ota-update-mechanism-comparison.md](./docs/ota-update-mechanism-comparison.md).

## 1. What this repository is

A NixOS flake that builds **ReCasaNix**, a NixOS spin of [ReCasaOS](https://github.com/EdmundFu-233/ReCasaOS):
a semi-embedded, vendor-managed NAS appliance OS for a custom developed NAS — an N200-based x86_64
board (eMMC boot, NVMe/SATA data disks, 4 GB RAM baseline).
<!-- REVIEW: "custom developed NAS" replaces the hardware's product name. -->

ReCasaOS is the security-maintained fork of CasaOS, which has been neglected upstream for a while.
ReCasaNix is not a fork of ReCasaOS: it tracks upstream, pinned to upstream's own validated component
set, and carries only the patches an image-based, Nix-managed host requires (§6, T9).

Two build products, both from one `nixosConfiguration`:

| Output | Purpose |
|---|---|
| `nixosConfigurations.recasanix-vm` + `packages.<sys>.vm` | Runnable QEMU VM of the full OS, for development and automated tests |
| `packages.<sys>.image` | Flashable GPT disk image for the hardware prototype |

The OS is an integration product, not a from-scratch one. It composes:

- **NixOS** — reproducible, immutable vendor-managed base.
- **ReCasaOS** — the web UI and app/device management layer (security-maintained CasaOS fork).
- **Docker** — container runtime backing the CasaOS app store.

## 2. Decisions already made — do not relitigate

These were settled with the product owner. If a task seems to require changing one, stop and ask.

| Topic | Decision |
|---|---|
| Base nixpkgs | FlakeHub `https://flakehub.com/f/NixOS/nixpkgs/0.1.tar.gz` (tracks nixpkgs-unstable) |
| Flake framework | **flake-parts** (not flake-utils) |
| Target arch | `x86_64-linux` only for the appliance; the dev shell also evaluates on `aarch64-linux` |
| OTA strategy | Long-term: NixOS build + **RAUC** A/B, dm-verity optional. **Phase 1: A/B-capable partition layout only** — no RAUC daemon, no bundles, no verity yet. Do not add Nix-daemon-on-device updating. |
| Bootloader | **systemd-boot** (UEFI). RAUC has a systemd-boot backend; revisit only if board firmware misbehaves. |
| Disk image | GPT via `image.repart` (`nix/modules/image.nix`): ESP, `root-a`, `root-b` (empty until RAUC), `state`, and a **blank** `data` partition grown on first boot. The data partition is not formatted: pools are hot state, created at runtime. Booted for real by check T6 (`image-boots`). |
| Storage (data pool) | **btrfs** (in-tree, native RAID1 mirror, snapshots). ZFS stays a documented, commented-out alternative that must remain cheap to test. |
| Storage manager | The UI's storage widget is served by **`recasanix-storage`** (`services/recasanix-storage`, our own Go code): the routes and shapes of upstream's CasaOS-LocalStorage, which is **not** adopted (host-management pattern, ext4-only, `bash -c` with request data, rclone). It **can create storage** on a blank disk (JBOD: btrfs single profile, no partitioning) — formatting/removing an *existing* storage and merging remain refused with 501. Every write re-validates its target against a fresh disk listing; nothing from a request reaches a command unchecked. The rest (mirror as a UI choice, replace, degraded, scrub) is the Phase 6 storage layer, on the same routes. See [docs/storage-manager.md](./docs/storage-manager.md). |
| Container runtime | **Docker** (`virtualisation.docker`). Podman re-evaluation is a later phase task, not now. |
| ReCasaOS pinning | Pin of record: upstream root `release/components.lock.json` (upstream's validated set). Component **with open upstream PRs** (ours): flake input = our fork's `recasanix-preview` branch = lock rev + PR branches merged in order (`nix/pins/preview.json`) → post-merge preview via the normal source mechanism. Others: upstream at the lock rev. `nix/pins/update.sh` = only way to move pins (rebuilds previews, pushes, locks). T7: lock rev == preview base (or input), input == preview head. Merged PR → drop from `preview.json`. (Owner decision 2026-10-07; replaces "plain upstream inputs + PR content as patches".) |
| Web UI source | `EdmundFu-233/ReCasaOS-UI` (maintained fork of the unmaintained `IceWhaleTech/CasaOS-UI`; see §6 for the licensing caveat). |
| CI | Local `nix flake check` for now. CI pipeline + binary cache is a later phase. |
| Cold vs hot state | **Nix owns the cold layer**: packages, service enablement, base network and storage *layout*, container-runtime setup, drivers, firewall, boot — infrequent, fleet-wide, atomic. **Hot state is imperative and is not routed through Nix**: users (ordinary useradd/PAM-style, `users.mutableUsers = true`), Samba/NFS shares, btrfs/ZFS pool and dataset topology (runtime `mkfs.btrfs`/`btrfs`/`zpool`/`zfs`; no NAS OS declares pools as system config), installed apps/containers, client network config. The CasaOS services already work the TrueNAS-middlewared way — structured records in their own databases, a generator step templates config files (e.g. `smb.casa.conf`, validated with `testparm`) and reloads the service — so we adopt that pattern instead of fighting it. |
| SMB (decided 2026-10-07) | Samba is **enabled** in the appliance module. **Separate SMB accounts**: dedicated accounts created from the UI/API (no shell, no host login), separate from the CasaOS login, shares restricted per account (`valid users`); imperative hot state (`useradd` + `smbpasswd`, passdb on the state partition). **Nix owns `smb.conf`** (store baseline with `include =` the runtime `smb.casa.conf`); casaos writes only the include file — an *include-only mode* contributed upstream to EdmundFu-233/ReCasaOS, not a local patch. Account model ported from the ReCasaOS-org fork (COMPARISON-FORKS.md, harvest #3). |
| Baseline + include | Where hot state needs a config file, ship an **immutable baseline** from the store and let the mutable part come in through an *include/override* (`include =` in smb.conf, systemd drop-ins, `conf.d/`), living on the writable state partition. Never make Nix regenerate a config on a password/share change. A `clan.lol`-style inventory is the reference if a fleet-wide runtime layer is ever needed. |
| Our own license | Intended OSS (AGPL candidate) for *our* glue code. Upstream Apache-2.0 components keep their license. |

## 3. Repository layout (target shape)

This is the shape the repository has grown into (phases 0–4 exist; RAUC and dm-verity are phase 6).
Create directories as tasks require them.

```
flake.nix                  # flake-parts: devShell, packages, nixosConfigurations, checks
flake.lock
nix/
  pkgs/                    # package derivations (none of these are in nixpkgs)
    recasaos/              #   root service ("casaos") + public-file portal; patches/
    recasaos-gateway/
    recasaos-user-service/
    recasaos-app-management/
    recasaos-message-bus/
    casaos-ui/             #   pnpm/vue static UI
    casaos-sysroot/        #   merged share/casaos-sysroot of all six components
    oapi-codegen-v1/       #   build tool: the generator version upstream's go:generate pins
    mk-casaos-go.nix       #   shared recipe of the Go services
    recasanix-storage/     #   the storage manager, incl. creating storage (our own code: services/recasanix-storage)
    default.nix            #   overlay assembling the above
  modules/                 # NixOS modules
    recasaos.nix           #   services.recasaos.* — units, configs, state dirs
    storage.nix            #   btrfs data-pool convention (+ commented ZFS alternative)
    state.nix              #   hot-state filesystem: accounts, ReCasaOS data/config, ssh host keys
    docker.nix             #   Docker on the data pool (skipped without a pool)
    image.nix              #   image.repart GPT layout (A/B capable), UKI on the ESP, first-boot growth
    appliance.nix          #   branding, hardening, console, first-boot
    hardware-n200.nix      #   board specifics (firmware, microcode, initrd modules); TODOs until hardware arrives
  hosts/                   # nixosConfigurations: recasanix-vm (development), recasanix-image (hardware)
  tests/                   # flake checks: unit, pin-drift, lint, no-host-management, NixOS VM tests
services/recasanix-storage/  # ReCasaNix's OWN Go services (not upstream components): the storage manager
  lib/                     # components.nix (pins), exclusions.nix (guardrail register)
  pins/update.sh           # re-pin every component
docs/upstream-exclusions.md  # generated from nix/lib/exclusions.nix (guardrail register, checked by T9)
```

## 4. Upstream facts an agent needs (verified 2026-09-20)

ReCasaOS consists of six repositories under `github.com/EdmundFu-233/`; the authoritative
pinned set is `release/components.lock.json` in the root repo.

| Component | Repo | Go module path | Binary | Config |
|---|---|---|---|---|
| Root service | `ReCasaOS` | `github.com/IceWhaleTech/CasaOS` | `casaos` | `/etc/casaos/casaos.conf` |
| Gateway | `ReCasaOS-Gateway` | `github.com/IceWhaleTech/CasaOS-Gateway` | `casaos-gateway` | (gateway ini) |
| User service | `ReCasaOS-UserService` | `github.com/EdmundFu-233/ReCasaOS-UserService` | `casaos-user-service` | `/etc/casaos/user-service.conf` |
| App management | `ReCasaOS-AppManagement` | `github.com/IceWhaleTech/CasaOS-AppManagement` | `casaos-app-management` | `/etc/casaos/app-management.conf` |
| Message bus | `ReCasaOS-MessageBus` | `github.com/IceWhaleTech/CasaOS-MessageBus` | `casaos-message-bus` | `/etc/casaos/message-bus.conf` |
| Web UI | `ReCasaOS-UI` (fork of `IceWhaleTech/CasaOS-UI`) | — (pnpm 9 / vue-cli) | static files | served from `/var/lib/casaos/www` |

Unit start order taken from the upstream `build/sysroot/usr/lib/systemd/system/*.service` files:

```
casaos-gateway  →  casaos-message-bus  →  { casaos, casaos-user-service, casaos-app-management }
                                          casaos-app-management also After=docker.service
                                          casaos also After=rclone.service
```

All units are `Type=notify`, `Restart=always`, and write PIDs into `/var/run/casaos/`.
Each repo carries a `build/sysroot/` tree (units, shell helpers, static assets) — harvest it in the
derivation rather than hand-writing paths.

Build quirks:

- Root `ReCasaOS` builds with `CGO_ENABLED=1 CGO_LDFLAGS=-static` and then runs UPX. **Skip UPX in
  Nix** (non-reproducible, breaks debugging); a dynamically linked `buildGoModule` build is fine.
- Root `go.mod` requires **Go 1.26** (`pkgs.go_1_26` exists in nixpkgs unstable). The other
  components declare 1.20/1.21 and build with the default `pkgs.go`.
- `ReCasaOS`'s `make build-ui` is deliberately disabled upstream; the UI must be built from its own
  repo with pnpm (`pnpm build` → `build/sysroot/var/lib/casaos/www/`).
- Nothing CasaOS-related exists in nixpkgs. Every component needs a derivation here.

## 5. Working conventions

- **Verify, don't assume.** nixpkgs moves fast and your training data lags it. Use the `mcp-nixos`
  tools (`nix` / `nix_versions`) to confirm any package name, attribute or NixOS option before
  writing it into the flake.
- Enter the dev shell (`nix develop`) for `python3`, `jq`, `go_1_26`, `pnpm`, `qemu`, `rauc`,
  `systemd-repart` and friends. Ad-hoc tools: `,` or `nix-shell -p`.
- New files must be `git add -N`'d before `nix flake check` will see them — Nix ignores untracked
  files in a git tree.
- Format with `nix fmt` (nixfmt-rfc-style) before finishing a task.
- Every derivation gets `meta.description`, `meta.license` and `meta.platforms`.
- **Telegram style, no prose**: docs, issues, PR descriptions (also upstream), commit bodies, code comments.
  Bullets, tables, fragments. Brief and clear.
- **Patches vs upstream PRs.** A change to an upstream component that is useful to upstream (bug
  and security fixes, integration breaks, features) goes to upstream as a PR — bounded, one concern
  per PR, interdependent PRs stacked with their order stated — and is consumed through the
  preview branch (`nix/pins/preview.json`) until upstream merges it. Only changes that make sense
  solely for an image-based, Nix-managed host (host-management stripping) stay local patches in
  `nix/pkgs/<component>/patches/`. Working clones of the forks live in `~/devel/github.com/ppenguin/ReCasaOS-EF/`
  (`<repo>-EF`, PR source) and `~/devel/github.com/ppenguin/ReCasaOS/` (`<repo>-RCOS`, reference).
- Pins go in `flake.lock` via flake inputs; never fetch from the network inside a derivation except
  through a fixed-output fetcher with a recorded hash.
- Keep vendor hashes (`vendorHash`, `pnpmDeps.hash`) in the derivation files, not in a side file.
  When a pin moves, set the hash to `lib.fakeHash`, build once, and paste the reported hash.
- Prefer upstream NixOS mechanisms (`image.repart`, `systemd.tmpfiles`, `testers.runNixOSTest`)
  over bespoke scripts.
- **Resolve runtime tools through the session, not through the source.** When a shipped script or
  service shells out to `lsblk`, `docker`, `smartctl` and the like, give the systemd unit a `path`
  — the unit is the session that populates the environment for everything running under it, exactly
  as a desktop or login session does — rather than rewriting the script's command names into store
  paths. `lib.getExe` is for a binary referenced directly from Nix; `path` is for anything resolved
  from inside a script.
- **Shell scripts keep `#!/usr/bin/env bash` shebangs.** NixOS guarantees `/usr/bin/env` and
  `/bin/sh`, but not `/bin/bash`. Normalise a `#!/bin/bash` shebang to `env`, put `pkgs.bash` on
  the consuming unit's `path`, and do not run `patchShebangs` on scripts that are executed by a
  service we control. Deleting a hardcoded `/usr/bin/` prefix so `PATH` resolves the command is a
  fix; `substituteInPlace`-ing a store path in is usually not. Binary patching (`patchelf`) is for
  prebuilt blobs with no source — it has no place in this repo, where everything is built from
  source.

## 6. Open items and hazards

- **UI licensing.** Neither `IceWhaleTech/CasaOS-UI` nor `EdmundFu-233/ReCasaOS-UI` contains a
  LICENSE file — the ReCasaOS lock records the UI as `no-license-file-upstream-all-rights-reserved`.
  The Go components *are* Apache-2.0. This is fine for internal prototypes; it must be resolved with
  upstream before commercial distribution. Mark the UI derivation's `meta.license` as
  `lib.licenses.unfree` with a comment.
- **Upstream's host-management machinery must be stripped, continuously.** ReCasaOS assumes it owns
  a mutable Debian host: it installs itself, rewrites system config, enables units and updates over
  the network. On ReCasaNix the Nix build and image pipeline own all of that. Every such script,
  route and UI affordance is a privileged path that must not ship — and the instances found so far
  are not the complete set. This is a standing guardrail with its own section and enforcing check
  (T9) in DEVELOPMENT.md; read it before any packaging or module task, and add what you find to
  `docs/upstream-exclusions.md`.
- **Cold/hot boundary.** CasaOS expects to write `/etc/casaos/*.conf`, `/var/lib/casaos`, `/var/run/casaos`,
  `/etc/samba/smb.casa.conf` and (as an ordinary account manager) the user database. Per the *Cold vs hot state*
  and *Baseline + include* decisions in §2: vendor-owned baselines come from the store, hot state lives on the
  writable state partition (including `/etc/passwd`, `/etc/shadow`, `/etc/group`, since users are mutable),
  and mutable files are reached through includes/overrides rather than by Nix regenerating them. Getting this
  boundary right is the central design problem of the whole project — see DEVELOPMENT.md task 3.2.
- **No hardware yet.** `hardware-n200.nix` stays a stub. Everything must be demonstrable in a VM.
- **CasaOS security posture.** The fork exists because upstream CasaOS carries RCE-class CVEs. Do
  not expose CasaOS ports beyond the VM's port forward, and do not weaken the fork's hardening
  (`UMask=0077`, the SMB-credential and public-files systemd admission units).
- `rclone.service` is referenced by `casaos.service` (`After=`). It is a soft ordering dependency;
  decide per task 3.1 whether to ship rclone.

## 7. Definition of done for any task

1. `nix flake check` passes (and the relevant new check is in `checks.x86_64-linux`).
2. `nix fmt` is clean.
3. The task's own acceptance criteria in DEVELOPMENT.md are met and verifiable by a command.
4. DEVELOPMENT.md's status column is updated in the same commit.
