# AGENTS.md — ReCasaNix

Orientation for coding agents working in this repository. Read this before touching the flake.
The executable task list lives in [DEVELOPMENT.md](./DEVELOPMENT.md); product rationale is in
[README.md](./README.md) and [ota-update-mechanism-comparison.md](./docs/ota-update-mechanism-comparison.md).

## 1. What this repository is

> **Branch `recasaos-based` (trial, owner decision pending):** base = the ReCasaOS **org**
> (`github.com/ReCasaOS/*`) instead of `EdmundFu-233/ReCasaOS` ("EF"). Rationale and PR set:
> COMPARISON-FORKS.md, "Re-assessment 2026-10-23". `main` / `integrate-EF+PRs` stay on EF.

A NixOS flake that builds **ReCasaNix**, a NixOS spin of [ReCasaOS](https://github.com/ReCasaOS/CasaOS):
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
| ReCasaOS pinning | Pin of record: `ReCasaOS/CasaOS-Install` `release/components.env` + `release/modules.env` at a release (tag + commit per component and per module; flake input `recasaos-install`). Modules (today `virt`, CasaOS-VirtManagement) are built into the image like components and enabled per box from the Modules page (core image provider: flag file + unit start; `nix/modules/recasaos-modules.nix`); their Debian package lists are replaced by nixpkgs equivalents there. Component **with open upstream PRs** (ours): flake input = our fork's `recasanix-staging` branch = pin + PR branches merged in order (`nix/pins/staging.json`) → post-merge preview via the normal source mechanism. Others: upstream at the pinned commit. CasaOS-Common (Go dependency): only while it has open PRs of ours, its staging replaces every service's go.mod version (`go mod edit -replace`); otherwise each go.mod as upstream has it. `nix/pins/update.sh [<install-rev>]` = only way to move pins (rebuilds staging, pushes, locks). T7: pin == staging base (or input), input == staging head, root still requires the recorded Common version. Merged PR → drop from `staging.json`. (EF scheme, owner decision 2026-10-07, carried over.) |
| Web UI source | `ReCasaOS/CasaOS-UI` (Vue 3, dark theme; Apache-2.0 + NOTICE, residual gap in §6). |
| CI | Local `nix flake check` for now. CI pipeline + binary cache is a later phase. |
| Cold vs hot state | **Nix owns the cold layer**: packages, service enablement, base network and storage *layout*, container-runtime setup, drivers, firewall, boot — infrequent, fleet-wide, atomic. **Hot state is imperative and is not routed through Nix**: users (ordinary useradd/PAM-style, `users.mutableUsers = true`), Samba/NFS shares, btrfs/ZFS pool and dataset topology (runtime `mkfs.btrfs`/`btrfs`/`zpool`/`zfs`; no NAS OS declares pools as system config), installed apps/containers, client network config. The CasaOS services already work the TrueNAS-middlewared way — structured records in their own databases, a generator step templates config files (e.g. `smb.casa.conf`, validated with `testparm`) and reloads the service — so we adopt that pattern instead of fighting it. |
| SMB (decided 2026-10-07) | Samba is **enabled** in the appliance module. **Separate SMB accounts**: dedicated accounts created from the UI/API (no shell, no host login), separate from the CasaOS login, shares restricted per account (`valid users`); imperative hot state (`useradd` + `smbpasswd`, passdb on the state partition). **Nix owns `smb.conf`** (store baseline with `include =` the runtime `smb.casa.conf`); casaos writes only the include file — *include-only mode* (`[server] SambaMainConfig = external`), upstream PR branch `feat/samba-include-only` (org, on CasaOS#42), not a local patch. Account model: the org's own. |
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
    recasaos-virt-management/ # module (modules.env): virtual machines (libvirt/QEMU)
    casaos-ui/             #   pnpm/vue static UI
    casaos-sysroot/        #   merged share/casaos-sysroot of all six components
    oapi-codegen-v1/       #   build tool: the generator version upstream's go:generate pins
    mk-casaos-go.nix       #   shared recipe of the Go services
    recasanix-storage/     #   the storage manager, incl. creating storage (our own code: services/recasanix-storage)
    default.nix            #   overlay assembling the above
  modules/                 # NixOS modules
    recasaos.nix           #   services.recasaos.* — units, configs, state dirs
    recasaos-modules.nix   #   modules of the image (virt): units, libvirtd, catalogue entries
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

## 4. Upstream facts an agent needs (org, verified 2026-10-23)

ReCasaOS (org) consists of these repositories under `github.com/ReCasaOS/`; the authoritative
pinned set is `release/components.env` in `CasaOS-Install` (one per distribution release, `v0.5.x`).

| Component | Repo | Go module path | Binary | Config |
|---|---|---|---|---|
| Root service | `CasaOS` | `github.com/ReCasaOS/CasaOS` | `casaos` | `/etc/casaos/casaos.conf` |
| Gateway | `CasaOS-Gateway` | `github.com/ReCasaOS/CasaOS-Gateway` | `casaos-gateway` | `/etc/casaos/gateway.ini` |
| User service | `CasaOS-UserService` | `github.com/ReCasaOS/CasaOS-UserService` | `casaos-user-service` | `/etc/casaos/user-service.conf` |
| App management | `CasaOS-AppManagement` | `github.com/ReCasaOS/CasaOS-AppManagement` | `casaos-app-management` | `/etc/casaos/app-management.conf` |
| Message bus | `CasaOS-MessageBus` | `github.com/ReCasaOS/CasaOS-MessageBus` | `casaos-message-bus` | `/etc/casaos/message-bus.conf` |
| Web UI | `CasaOS-UI` (Vue 3) | — (pnpm / vue-cli 5) | static files | served from `/var/lib/casaos/www` |
| Shared library | `CasaOS-Common` | `github.com/ReCasaOS/CasaOS-Common` | — (Go dependency) | — |
| Module (in the image, off until enabled) | `CasaOS-VirtManagement` | `github.com/ReCasaOS/CasaOS-VirtManagement` | `casaos-virt-management` | `/etc/casaos/virt-management.conf` |
| Not shipped | `CasaOS-LocalStorage` (→ `recasanix-storage`), `CasaOS-Install` (pin of record only), `_appstore` (mirror) | | | |

Service auth: per-boot `/run/casaos/internal.secret` (gateway writes it, root-only); in-stack callers
send `Authorization: Internal <secret>` from loopback. Users: the bare access token in
`Authorization` (`?token=` on GET subscription routes only).

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

- No cgo anywhere (sqlite = glebarez/modernc): `CGO_ENABLED=0`. **Skip UPX** (non-reproducible).
- Every `go.mod` requires **Go 1.26.x** (patch level moves with upstream: nixpkgs `go` must be ≥ it).
- `codegen/` is gitignored and made by `go generate` from the network (oapi-codegen@v1.12.4, a floating
  message-bus spec URL) → derivations run the pinned `oapi-codegen-v1` on the pinned message-bus spec.
- The UI is built from its own repo with pnpm (`pnpm build` → `build/sysroot/var/lib/casaos/www/`).
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
  staging branch (`nix/pins/staging.json`) until upstream merges it. Only changes that make sense
  solely for an image-based, Nix-managed host (host-management stripping) stay local patches in
  `nix/pkgs/<component>/patches/`. Working clones of the forks live in `~/devel/github.com/ppenguin/ReCasaOS/`
  (`<repo>-RCOS`, PR source on this branch) and `~/devel/github.com/ppenguin/ReCasaOS-EF/` (`<repo>-EF`).
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

- **UI licensing** (status 2026-10-23):

  | Code | Licence |
  |---|---|
  | IceWhale `CasaOS-UI` | Apache-2.0 since 2026-10-12 (`LICENSE`, IceWhaleTech/CasaOS-UI@400a22c) |
  | `ReCasaOS/CasaOS-UI`: org maintainer's changes (Vue 3, dark theme, …) | Apache-2.0 (`LICENSE` + `NOTICE`, ReCasaOS/CasaOS#16, ReCasaOS/CasaOS-UI#30) |
  | `ReCasaOS/CasaOS-UI`: alvins82's pre-org commits | **open** — NOTICE does not cover them; ask alvins82/CasaOS-UI |
  | `EdmundFu-233/ReCasaOS-UI`: EF's own commits (4, 2026-09-15/16) | **open** — no `LICENSE` in that repo; EF lock still says `no-license-file-upstream-all-rights-reserved` |

  - residual gap = small, third-party authors only; close before commercial distribution
  - UI derivation keeps `meta.license = lib.licenses.unfree` until the source in use is fully covered
    (EF adds `LICENSE`, or switch to the org UI + alvins82 answer) → then `asl20`, drop `allowUnfreePredicate`
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
