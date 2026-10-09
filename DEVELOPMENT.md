# DEVELOPMENT.md — ReCasaNix prototype plan

Executable plan for building the ReCasaNix flake: a runnable VM and a flashable hardware image,
including Nix derivations for every ReCasaOS component (none are in nixpkgs).

Written to be worked through by a coding agent (e.g. Claude Code) mostly unattended. Read
[AGENTS.md](./AGENTS.md) first — it holds the settled decisions, upstream facts and conventions that
these tasks assume.

**How to use this document**: work tasks in order within a phase; phases 1 and 4 can overlap. Each
task states its deliverable, its acceptance criteria and the exact command that verifies it. Update
the Status column in the same commit that completes the task. `[ ]` = todo, `[~]` = in progress,
`[x]` = done, `[!]` = blocked (add a one-line reason).

## Goal state (end of this plan)

```
nix develop                                  # tooling shell
nix build .#casaos .#casaos-gateway ...      # every component builds
nix run .#vm                                 # boots; CasaOS UI reachable on localhost:8080
nix build .#image                            # GPT image, A/B layout, dd-able to eMMC
nix flake check                              # unit + NixOS VM integration tests all green
```

---

## ⚠️ Cross-cutting guardrail — strip upstream's host-management machinery

**Read this before every packaging and module task. It applies continuously, not once.**

ReCasaOS inherits CasaOS's assumption that it *owns and mutates a mutable Debian host*: it installs
itself, edits system config in place, enables and disables units, and updates itself over the
network. On ReCasaNix, every one of those responsibilities belongs to the Nix build and the image
pipeline instead. Shipping such machinery is not merely dead weight — it is a privileged,
attacker-reachable path that either silently fails, corrupts the state boundary of task 3.2, or
appears to work and leaves the device in a state the vendor image cannot reason about.

`cleanup/` (task 1.5.6) was the first instance found. **Assume there are many more.** Each new
component, and each upstream bump, is an occasion to look again.

### What to hunt for

| Category | Concrete instances already spotted | Disposition |
|---|---|---|
| Distro package lifecycle | `build/sysroot/usr/share/casaos/cleanup/**`, `build/scripts/setup/service.d/casaos/{debian,ubuntu,arch}/**`, `build/scripts/migration/**` | Do not ship |
| Self-update over the network | `shell/update.sh` (upstream stub, hard-exits), `route/v1/system.go: SystemUpdate` → `service.System().UpdateSystemVersion()`, `GetSystemCheckVersion` | Do not ship; disable the route |
| Unit enable/disable at runtime | `shell/delete-old-service.sh`, anything calling `systemctl enable/disable/daemon-reload` | Do not ship; units are declarative |
| In-place config rewriting | the `setup-casaos.sh` family writing `/etc/casaos/*.conf` | Superseded by task 3.2 |
| Process/host lifecycle from the UI | `PostKillCasaOS`, `PutSystemState` | Review individually — reboot may be legitimate, self-kill is not |
| Package-manager invocations | any `apt`, `apt-get`, `dpkg`, `pacman`, `yum` call | Do not ship |
| The upstream installer | the `ReCasaOS-Installer` component in `components.lock.json` | Not packaged at all |

### The rule

1. **Do not ship it.** Exclude it in the derivation's install phase — explicitly, by path, so that
   an upstream bump adding a new file under an excluded directory fails loudly rather than
   smuggling it in.
2. **Cut the caller too.** A removed script with a live UI button or API route still reachable is
   worse than shipping it: the user gets a broken control instead of no control. Trace each removal
   to its API handler and its UI affordance, and disable both. Record UI edits as patches against
   `casaos-ui`, not as post-build file surgery.
3. **Record the decision.** Append every exclusion to `docs/upstream-exclusions.md` as
   `path | why | what replaces it | caller disabled? (route, UI)`. This file is the review artefact
   for upstream bumps and for the eventual conversation with the ReCasaOS maintainer — upstream may
   well accept a build flag for this, which is cheaper for us than carrying patches.
4. **Prefer disabling over deleting where the UI would break badly.** If cutting an affordance is
   more work than the prototype warrants, leave it visibly non-functional and file it in the
   exclusions register with a `TODO`, rather than leaving a privileged path live.
5. **When in doubt, ask.** "Does this script manage the host?" is usually obvious. If it is not,
   flag it rather than guessing — a wrongly-kept script is a security finding, a wrongly-removed one
   is a bug report.

**What is *not* host management.** Runtime generators of *hot state* are the intended architecture, not
machinery to strip: CasaOS's shares service compiling its database into `smb.casa.conf`, validating with
`testparm` and reloading smbd; user and app management through its own databases; the UI's event
registration hook. The line is *who owns the host*: installers, in-place self-update, unit
enable/disable, package managers and ad-hoc scripts that rewrite vendor-owned system config are out; a
service maintaining its own records and the config derived from them is in (via the include/override
pattern of task 3.2).

Enforced mechanically by check **T9**.

---

## Phase 0 — Foundations

| ID | Status | Task |
|---|---|---|
| 0.1 | [x] | flake-parts skeleton with dev shell |
| 0.2 | [x] | Component pin helper |
| 0.3 | [x] | Package/overlay scaffolding |
| 0.4 | [x] | Exclusions register (guardrail infrastructure) |

### 0.1 — flake-parts skeleton *(done)*

`flake.nix` exists with FlakeHub nixpkgs 0.1, flake-parts, a dev shell and `nix fmt`.

### 0.2 — Component pin helper

**Deliverable**: `nix/lib/components.nix`, and a re-pin script `nix/pins/update.sh`. *(Revised
from the original plan, which vendored a copy of the lock file: the lock file lives in the root
repository, so the root revision **is** the pin of record and nothing is vendored.)*

**Design**

1. The six ReCasaOS repos are flake inputs with `flake = false` and **unpinned** URLs in `flake.nix`
   (`recasaos`, `recasaos-gateway`, `recasaos-user-service`, `recasaos-app-management`,
   `recasaos-message-bus`, `casaos-ui` from `github:EdmundFu-233/ReCasaOS-UI`). Their revisions and
   `narHash`es live in `flake.lock`.
2. `nix/lib/components.nix` reads `release/components.lock.json` out of the pinned `recasaos` input
   and exposes `{ name -> { rev, inputRev, repo, license, src }; }`: `rev` is what upstream's lock
   file requires, `inputRev` what `flake.lock` holds. Derivations and the drift check (T7) share it.
3. `nix/pins/update.sh [<root-rev>]` moves `recasaos` (`nix flake update recasaos`, or to a given
   revision), then pins every other input to the revision the new lock file names with
   `nix flake lock --override-input <input> github:<owner>/<repo>/<rev>` and prints a before/after
   listing. The root is not listed in its own lock file, so it pins to the revision it landed on.
4. **Never** run a bare `nix flake update`, or update a single component input on its own: that
   floats it to the branch head, away from upstream's validated set. T7 catches it; the script fixes it.

**Acceptance**: `nix eval .#lib.components --json | jq` lists six components with 40-char revs, and
every `rev` equals its `inputRev`.

**Verify**: `nix eval --json .#lib.components | jq -e 'length == 6'` and
`nix build .#checks.x86_64-linux.pin-drift`

### 0.3 — Package/overlay scaffolding

**Deliverable**: `nix/pkgs/default.nix` exporting an overlay, wired into `perSystem` so all
component packages appear under `packages.x86_64-linux.*`, plus `legacyPackages` for exploration.

**Acceptance**: `nix flake show` lists the (still empty) package set without evaluation errors.

### 0.4 — Exclusions register

Do this **before** the first derivation, so the guardrail has somewhere to write from task 1.1
onward instead of being retrofitted.

**Deliverable**: `nix/lib/exclusions.nix` (the machine-readable list, per component: paths to drop
from the sysroot plus the routes/UI affordances to disable) and `docs/upstream-exclusions.md` (the
human-readable register described in the guardrail).

**Steps**

1. Seed `exclusions.nix` with what is already known: `usr/share/casaos/cleanup`,
   `build/scripts/setup`, `build/scripts/migration`, `shell/update.sh`, `shell/delete-old-service.sh`.
2. Expose a helper the derivations call in `installPhase` — it must **fail** if a listed path is
   absent, so a path upstream renames is caught instead of silently becoming a no-op exclusion.
3. Seed `docs/upstream-exclusions.md` with a row per entry.

**Acceptance**: `nix eval .#lib.exclusions --json | jq` returns the seeded set, and every entry has
a matching row in the register.

**Verify**: covered by T9.

*As built*: `docs/upstream-exclusions.md` is not hand-edited — it is `exclusions.register` rendered
from `nix/lib/exclusions.nix` (`nix build .#exclusions-register && install -m644 result
docs/upstream-exclusions.md`), and T9 fails if the committed file differs. Entries have a kind:
`path` (not shipped, existence asserted), `patch` (source/script patched — patch files live next to
the package), `finding` (spotted, recorded, possibly a `TODO` for a later task).

---

## Phase 1 — Component derivations

Each of the five Go services follows the same recipe; do 1.1 carefully, then 1.2–1.5 are mechanical.

| ID | Status | Task |
|---|---|---|
| 1.1 | [x] | `casaos-gateway` derivation (reference implementation) |
| 1.2 | [x] | `casaos-message-bus` derivation |
| 1.3 | [x] | `casaos-user-service` derivation |
| 1.4 | [x] | `casaos-app-management` derivation |
| 1.5 | [x] | `casaos` (root service) derivation |
| 1.6 | [x] | `casaos-ui` derivation (pnpm) |
| 1.7 | [x] | `casaos-sysroot` aggregate |

### 1.1 — `casaos-gateway` (do this one first, it is the template)

**Deliverable**: `nix/pkgs/recasaos-gateway/default.nix`.

**Steps**

1. `buildGoModule` on the pinned source; `vendorHash` obtained by building with `lib.fakeHash` once.
2. `subPackages` / `ldflags`: strip with `-s -w` and inject the version via the upstream `main`
   version variable if one exists (`grep -rn 'var Version' .`). **Do not run UPX.**
3. Install the upstream `build/sysroot/` tree into `$out/share/casaos-sysroot/` (units, shell
   helpers, assets) — downstream modules read it from there, so no path is hand-transcribed.
   Filter it through `nix/lib/exclusions.nix` (task 0.4) and apply the cross-cutting guardrail:
   **inspect what this component's sysroot actually contains before installing it**, and add any
   host-management machinery you find to the register.
4. `meta = { description; homepage; license = licenses.asl20; platforms = platforms.linux; };`
5. Run the upstream Go tests as a separate check (see Test strategy T1), not in `checkPhase`, so a
   flaky upstream test cannot block an image build.

**Acceptance**: `nix build .#casaos-gateway` produces `$out/bin/casaos-gateway` and
`$out/share/casaos-sysroot/usr/lib/systemd/system/casaos-gateway.service`.

**Verify**:
```sh
nix build .#casaos-gateway && \
  ./result/bin/casaos-gateway -v && \
  test -f result/share/casaos-sysroot/usr/lib/systemd/system/casaos-gateway.service
```

### 1.2–1.4 — `casaos-message-bus`, `casaos-user-service`, `casaos-app-management`

Same recipe as 1.1. Notes:

- `casaos-user-service` declares Go 1.26.6 in `go.mod` → pass `go = pkgs.go_1_26`.
- `casaos-user-service` ships extra units (`recasaos-user-bootstrap`,
  `recasaos-user-password-reset`, `recasaos-user-account-password-reset`) — keep them in the
  sysroot; task 3.1 decides which are enabled.
- `casaos-app-management` needs the Docker CLI at runtime, not at build time. Record the runtime
  dependency as a comment; the module (task 3.1) supplies it via the unit's `path`.

**Verify (each)**: `nix build .#<pkg> && ./result/bin/<binary> -v`

### 1.5 — `casaos` (root service)

Extra care: upstream builds with `CGO_ENABLED=1 CGO_LDFLAGS=-static`, requires **Go 1.26**
(`pkgs.go_1_26`) and pulls `glebarez/sqlite`, `go-smb2`, `go-socket.io`.

**Steps**

1. `buildGoModule` with `go = pkgs.go_1_26`. Start with the nixpkgs default `CGO_ENABLED=1`
   dynamic linking; do not chase upstream's static flags.
2. If cgo turns out to be unnecessary (check what actually needs it: `grep -rn 'import "C"'`),
   prefer `CGO_ENABLED=0` and note the deviation in the derivation.
3. Build `cmd/recasaos-public-files` as a second output binary (upstream's
   `make build-public-files`, `CGO_ENABLED=0 -tags "netgo osusergo"`); its socket-activated units
   are part of the fork's hardening and belong in the sysroot.
4. Ship the shell helpers from `build/sysroot/usr/share/casaos/shell/` (`helper.sh`,
   `usb-mount.sh`, `assist.sh`) **with no store paths baked in at all**:
   - Commands: they already invoke bare names (`lsblk`, `blkid`, `awk`, `free`, `getconf`,
     `timedatectl`, `docker`, `logger`, `mount`). Leave them bare — the service session's `PATH`
     resolves them (task 3.1).
   - Shebangs: normalise `#!/bin/bash` to `#!/usr/bin/env bash`. Do **not** run `patchShebangs`.
     NixOS guarantees `/usr/bin/env` (and `/bin/sh`) but not `/bin/bash`, so `env` keeps the script
     portable and lets the session decide which `bash` it gets — the same arrangement any heavy
     session (desktop, container, login shell) already relies on.

   A store-path shebang or a `substituteInPlace`-ed command path would pin the package to a runtime
   closure it does not own and diverge the scripts from upstream for no gain. Reserve path surgery
   for cases where a bare name genuinely cannot work.
5. Before assuming the set of tools, enumerate what the scripts actually call, and hand that list to
   task 3.1:
   ```sh
   grep -rhoE '^\s*[A-Za-z_][A-Za-z0-9_-]*|\$\([a-z][a-z0-9-]*' \
     build/sysroot/usr/share/casaos/shell/*.sh | sort -u
   ```
   Any genuine absolute path that turns up (`/bin/`, `/usr/bin/`, `/sbin/`) is a finding: prefer
   deleting the prefix so the system `PATH` resolves it.
6. Apply the **cross-cutting guardrail** in full — this component is the worst offender. Do not
   ship `usr/share/casaos/cleanup/`, `build/scripts/setup/`, `build/scripts/migration/`,
   `shell/update.sh` or `shell/delete-old-service.sh`, and disable the self-update route
   (`route/v1/system.go: SystemUpdate`, `GetSystemCheckVersion`) together with its UI affordance.
   Record each in `docs/upstream-exclusions.md`. Re-read the guardrail table before starting: the
   listed instances are what has been spotted so far, not a complete inventory.

**Acceptance**: `nix build .#casaos` yields `bin/casaos` and `bin/recasaos-public-files`; every
shell helper starts with `#!/usr/bin/env` and no `/nix/store`, `/usr/bin` or `/sbin` path is baked
into any of them.

**Verify**:
```sh
nix build .#casaos && ./result/bin/casaos -v
for f in result/share/casaos-sysroot/usr/share/casaos/shell/*.sh; do
  head -1 "$f" | grep -q '^#!/usr/bin/env ' || echo "REVIEW: $f — shebang is not /usr/bin/env"
done
# (the mandated shebang itself matches /usr/bin/, hence the filter)
grep -rnE '/nix/store/|(^|[^-[:alnum:]])/(usr/)?s?bin/[a-z]' \
    result/share/casaos-sysroot/usr/share/casaos/shell/ \
  | grep -v ':1:#!/usr/bin/env ' \
  && echo "REVIEW: baked-in paths above — strip them, let the unit's PATH resolve the command" \
  || echo "shell helpers clean"
```

### 1.6 — `casaos-ui`

**Deliverable**: `nix/pkgs/casaos-ui/default.nix` — the Vue app built from its pnpm lockfile (pnpm 10 — see "As built").

**Steps**

1. Use `pnpm.fetchDeps` (confirm the current nixpkgs API with mcp-nixos before writing it) with
   `pnpmDeps.hash` from `pnpm-lock.yaml`.
2. Build phase: `node message_bus.build.js && vue-cli-service build --dest <out> --mode production`.
   Upstream's `.env.production` decides API base paths — read it before overriding anything.
3. Install the result to `$out/share/casaos-sysroot/var/lib/casaos/www/`, matching the Go packages'
   sysroot convention.
4. `meta.license`: **not** Apache-2.0 — no LICENSE file exists upstream. Use
   `lib.licenses.unfree` with a comment pointing at AGENTS.md §6, and keep the source input
   trivially switchable to `EdmundFu-233/ReCasaOS-UI`.

**Acceptance**: `index.html` and a hashed JS bundle exist under the install path; the build runs
fully offline (no network in the build sandbox).

**Verify**: `nix build .#casaos-ui && test -s result/share/casaos-sysroot/var/lib/casaos/www/index.html`

### As built (phase 1 findings and deviations)

- **Shared recipe**: `nix/pkgs/mk-casaos-go.nix` (used by 1.1–1.5). Binaries are renamed from Go's
  package-directory name (`CasaOS-Gateway`) to the release name; `subPackages` is explicit so the
  Debian-host `cmd/migration-tool` is never built. Upstream versions are constants in the source
  (`common/version.go`, `common/constants.go`), so there is nothing to inject with `ldflags`.
- **Go toolchain**: nixpkgs' default `go` is 1.26.x, which satisfies every `go.mod` (incl. user-service's
  1.26.6) — no explicit `go = pkgs.go_1_26` needed today.
- **`casaos` root**: nothing uses cgo, so `CGO_ENABLED=0` with upstream's `netgo osusergo` tags (static;
  the public-file portal's `RootDirectory=` jail needs that anyway). The portal binary is also copied to
  `usr/lib/recasaos-public-files/rootfs/usr/bin/` in the sysroot, where its unit expects it.
- **`casaos-app-management`**: upstream gitignores `codegen/` and produces it with `go generate`, which
  downloads `oapi-codegen@v1.12.4` and the message-bus OpenAPI spec from that repo's floating `main`.
  Here the generator is a pinned tool (`nix/pkgs/oapi-codegen-v1`, nixpkgs' 2.x output does not compile
  against the vendored deps) and the spec comes from the *pinned* message-bus source.
- **Guardrail results** (all in `docs/upstream-exclusions.md`): patches remove the self-update routes
  and self-kill route from the root service and the host-management functions from `helper.sh`;
  `/bin/*` paths are gone. Notable finding: CasaOS-Common's `command.OnlyExec` hardcodes `/bin/bash`, so
  *every* `helper.sh` call would have failed on NixOS — the root service now uses its own bare-`bash`
  helper. The 1.5 verify snippet's own grep matched the mandated `#!/usr/bin/env` shebang; fixed above.
- **`casaos-ui`**: nixpkgs removed pnpm 9 (EOL), so `pnpm_10` reads the format-9 lockfile. pnpm skips
  dependency lifecycle scripts, so the `@vue-office/*` postinstall (which creates `lib/index.js`) is run
  explicitly. Patches drop the update UI and stop webpack from stringifying the whole build environment
  into the bundle (reproducibility; no store paths leak — the closure is just the output). The build also
  emits `etc/casaos/start.d/register-ui-events.sh` (run by casaos at start) and
  `var/lib/casaos/ui-message-bus.json`; the script's `/usr/bin/bash` shebang is normalised, and T9 pins
  `start.d` to that one file.
- **T1** (`checks.*.unit-*`): sandbox-incompatible upstream tests are skipped by name with a reason in
  `nix/tests/unit.nix` (setuid chmod, root-owned ancestors, Docker daemon, network/app store, systemd).
  Two things worth knowing: `casaos-ui` has no unit check because upstream's `pnpm test` runs `vitest`, which
  neither `package.json` nor the lockfile declares; and **upstream finding** — user-service's
  `TestRefreshRotationHandlerFlow` (and, with a nil-pointer panic in `PostUserRefreshToken`, `TestLogoutAllRetiresEverySession`) fail in ~90% of rapid repeated runs (`-count=200`): the token rotated
  before a replay is still accepted afterwards when everything happens within one wall-clock second, i.e. a
  probable second-granularity race in session-family revocation (`service/session.go`). It is skipped to keep the
  check deterministic and belongs in the conversation with the ReCasaOS maintainer.

### 1.7 — `casaos-sysroot` aggregate

**Deliverable**: a `symlinkJoin`-style package merging all six components'
`share/casaos-sysroot/` trees into one, so the NixOS module has a single input.

**Acceptance**: the merged tree contains all five `casaos*.service` units, the public-files
socket/service pair, the shell helpers and the UI `www/` directory, with no file collisions.

**Verify**: `nix build .#casaos-sysroot && find result -name '*.service' | sort`

---

## Phase 2 — Storage and appliance base

| ID | Status | Task |
|---|---|---|
| 2.1 | [x] | `nix/modules/storage.nix` — btrfs data pool |
| 2.2 | [x] | `nix/modules/appliance.nix` — base appliance policy |

### 2.1 — Storage module

**Deliverable**: `nix/modules/storage.nix` with options `recasanix.storage.{poolLabel, mountPoint}`.
*(Revised: the original plan declared `mode` and `devices`. Pool topology is hot state and always
imperative — see AGENTS.md §2, "Cold vs hot state" — so the module encodes a convention, not a topology.)*

**Steps**

1. Convention: a btrfs filesystem labelled `recasanix-data` (`poolLabel`) appears at `/var/lib/recasanix/data`
   (`mountPoint`; the path CasaOS shares and Docker volumes live under). It is created, extended and
   repaired at runtime — `mkfs.btrfs -L recasanix-data` (single), `-d raid1 -m raid1` (mirror) — by the
   first-run/storage layer (Phase 6), never by Nix. The mount is `noauto,x-systemd.automount`: a missing pool
   makes the mountpoint *unusable* instead of silently filling the small root device.
2. Enable `services.btrfs.autoScrub` and `services.smartd` (SMART warnings are an explicit product
   requirement) with notifications routed to the journal for now.
3. Do **not** format or partition anything. A wrong configuration can never destroy data at boot.
4. Keep a **commented-out ZFS alternative block** in the same file — `boot.supportedFilesystems`,
   `boot.zfs.*`, `networking.hostId`, `zpool` operations — with the CDDL redistribution and
   kernel-coupling caveats and how to flip to it, so the switch stays a cheap experiment.

**Acceptance**: the VM boots clean with no data disks and with two blank disks (nothing failed, disks
untouched), and a pool created at runtime is picked up by label and survives a reboot.

**Verify**: covered by test T3 (`checks.x86_64-linux.storage`).

### 2.2 — Appliance base module

**Deliverable**: `nix/modules/appliance.nix`.

Contents: hostname `recasanix`, `users.mutableUsers = true` (users are hot state; `/etc/passwd`, `shadow`,
`group` live on the state partition — task 3.2) plus a declarative *bootstrap* administrator with SSH keys
and an optional `initialHashedPassword`, `services.openssh` (key-only), `networking.firewall` opening only
80/443/22 and SMB when enabled, `boot.loader.systemd-boot`, `nix.enable = false` on the appliance profile (no Nix
daemon on device — see AGENTS.md §2), journald size caps, and `system.stateVersion`.

**Acceptance**: `nix build .#nixosConfigurations.recasanix-vm.config.system.build.toplevel` succeeds.

---

### As built (phase 2)

- **`fileSystems` in VMs**: `qemu-vm.nix` (the VM runner and every NixOS VM test) replaces the *whole*
  `fileSystems` set with `virtualisation.fileSystems`, silently dropping any module-defined mount.
  `storage.nix` therefore also feeds its pool to `virtualisation.fileSystems` when that option exists.
  Phase 3/4 modules that add mounts must do the same.
- **Automount, not `nofail`**: the pool mount is `noauto,x-systemd.automount`, so a diskless or blank-disk
  machine boots with *nothing* failed (an eager `nofail` mount leaves a failed `.mount` unit and a
  `degraded` system), and writes to the mountpoint without a pool fail instead of landing on the root
  device. smartd runs with `-q nodev0` so it does not fail in VMs without SMART devices; notifications go
  to the journal only. A mirror missing a member does not mount by label until mounted `degraded` — a
  runtime decision for the storage layer.
- **`recasanix-vm`** (`nix/hosts/recasanix-vm.nix`) is a minimal composition so 2.2 can be verified; it carries a
  development-only console password. Task 4.1 grows it (OVMF, serial console, port forwards, disks).
- **Users are hot state** (owner decision, AGENTS.md §2): `users.mutableUsers = true`; the declared admin is a
  bootstrap account with SSH keys and an `initialHashedPassword` that is applied once at creation. The
  account files must persist on the state partition (task 3.2). Passwordless sudo for the key-only admin is
  a prototype policy — `TODO(hardening)`.
- **Test assertion** "pulling one device… `smartd`/journal showing degradation" is implemented against the
  kernel's btrfs messages in the journal; smartd has no SMART data to report in a VM.

---

## Phase 3 — ReCasaOS NixOS module

The heart of the project. This is where the immutable/mutable boundary is decided.

| ID | Status | Task |
|---|---|---|
| 3.1 | [x] | `services.recasaos` — units and runtime wiring |
| 3.2 | [x] | Cold/hot state boundary |
| 3.3 | [x] | Docker integration |
| 3.4 | [x] | Storage manager, incl. creating storage (`recasanix-storage`) |

### 3.1 — `services.recasaos`

**Deliverable**: `nix/modules/recasaos.nix`.

**Steps**

1. Translate the upstream units into `systemd.services.*` rather than dropping the unit files in.
   Use `lib.getExe pkgs.casaos` (and friends) for `ExecStart`, and preserve upstream's
   `Type=notify`, `Restart=always`, `UMask=0077` and the ordering:
   `casaos-gateway → casaos-message-bus → { casaos, casaos-user-service, casaos-app-management }`.
2. **Make the service session path-aware — this is how the helpers get both their interpreter and
   their tools.** The Go services spawn `helper.sh` / `usb-mount.sh` as children, so the unit's
   `path` is inherited by the scripts and by every command they call. The scripts' `#!/usr/bin/env
   bash` shebang (task 1.5.4) resolves `bash` from that same `PATH`, so **`pkgs.bash` must be on the
   list** — treat the unit exactly like any other heavy session that populates an environment for
   the programs running under it. From the list task 1.5.5 produced:

   ```nix
   systemd.services.casaos.path = with pkgs; [
     bash            # the helpers' #!/usr/bin/env bash interpreter
     util-linux      # lsblk, blkid, mount, umount
     coreutils gawk gnugrep
     systemd         # timedatectl, logger
     smartmontools   # SMART queries
     e2fsprogs dosfstools ntfs3g exfatprogs   # mkfs/fsck for the filesystems we accept
   ];
   ```

   Keep this list minimal and justified: it is the appliance's effective privileged toolbox.
   `lib.getExe`/`lib.getExe'` remains the right form for a single binary referenced directly from
   Nix (e.g. an `ExecStartPre=`); `path` is the right form for anything resolved from inside a
   script. A missing entry here surfaces as a runtime `command not found` in the journal, not as a
   build failure — T2 should assert the helpers actually run, not merely that the units start.
3. `casaos-app-management` additionally `After=docker.service`, with
   `path = [ pkgs.docker pkgs.docker-compose ]`.
4. `usb-mount@.service` is a udev-triggered template unit and hardcodes `/DATA/USB_Storage_*` as its
   mount root. Decide here whether removable-media mounting is in prototype scope; if yes, define
   the template as a NixOS unit with its own `path` and point the mount root at the data pool
   instead of `/DATA`.
5. Create `/var/run/casaos`, `/var/lib/casaos` and `/etc/casaos` via `systemd.tmpfiles.rules` with
   the right ownership before the units start.
6. Serve the UI from `/var/lib/casaos/www` by symlinking the `casaos-ui` store path (the gateway
   serves static files from there).
7. Decide on `rclone`: `casaos.service` has `After=rclone.service`. If CasaOS's cloud-drive mounting
   is out of scope for the prototype, drop the ordering and record it here; otherwise ship
   `pkgs.rclone` with a matching unit.
8. Options: `services.recasaos.{enable, package, uiPackage, httpPort, dataDir}` (plus `fileRoots`, see below).

**Acceptance**: in the VM, all five units reach `active (running)` and `curl localhost:80` returns
the UI's `index.html`.

**Verify**: test T2 (`checks.x86_64-linux.recasaos-boot`).

*As built (3.1)* — `nix/modules/recasaos.nix`; `nixosModules.recasaos` needs `overlays.default` and the
UI's unfree allowance in `pkgs` (the flake's `recasanix-vm` and the tests provide both):

- **Units** are hand-translated (`Type=notify`, `Restart=always`, the upstream order, `UMask=0077` on
  user-service). Dropped on purpose: upstream's `ExecStartPre=<bin> -v` (prints a version) and `PIDFile=`
  (redundant with notify). Not translated: the SMB-credential drop-in and the public-files
  socket/service pair — both stay in the sysroot, inert, and belong with the Phase 6 SMB/portal hardening.
- **`casaos` PATH** = the task's list plus `procps` (`free`), `glibc.bin` (`getconf`) and `curl`
  (`register-ui-events.sh`), each of which a shipped script calls. T2 sources `helper.sh` in the unit's
  own `PATH` and fails on `command not found`.
- **Decisions**: rclone stays dropped (no `After=rclone`). Removable-media mounting is *deferred*, not
  dropped — owner decision: reinstate it later as a NixOS-native template unit plus udev rule (no
  `usb-mount@` unit yet; the register tracks it), once the major topics are tested. `docker.service`
  ordering is in place; Docker itself is 3.3.
- **`fileRoots`** (new option, default `/DATA`): the root service pins its management roots at startup and
  panics if one is missing (`RECASAOS_MANAGEMENT_FILE_ROOTS`; upstream's default `/DATA,/mnt,/media` does
  not exist on NixOS). They are created on the root filesystem so the UI comes up even with no data pool;
  pools get mounted below them at runtime. Note this is `/DATA`, not `/var/lib/recasanix/data` — an automounted
  pool path would make startup depend on the pool. **Resolved in 3.3:** the pool at
  `/var/lib/recasanix/data` is bind-mounted over `/DATA` (its `DATA` directory) when present — see 3.3.
- **Interim state handling** (3.2 refines it): configs are seeded from upstream's samples by
  `systemd-tmpfiles` (`C`, never overwritten; the gateway seed carries `httpPort`), `/etc/casaos/env` is
  created empty, `/var/lib/casaos/db` is pre-created (without it message-bus fails its first start and only
  `Restart=always` hides it — T2 asserts `NRestarts=0`), the UI tree, `ui-message-bus.json` and the single
  `start.d` hook are vendor-owned symlinks refreshed each boot, and `/usr/share/casaos/shell` points at the
  sysroot so nothing in the shell scripts or Go config needs path surgery. `dataDir` is the seam: when it
  differs from `/var/lib/casaos`, that path becomes a symlink to it.
- **Local administrator bootstrap**: the fork never takes a setup secret over HTTP — `POST /v1/users/register`
  answers `410 Gone` and the UI's "register" screen can only show "network registration is disabled". The
  first administrator (and any password reset) is created locally through three disabled oneshot units
  (`recasaos-user-bootstrap`, `-password-reset`, `-account-password-reset`; credentials via `LoadCredential`
  from root-only `/run` files). The module ships them plus **`recasanix-user-admin`** (`bootstrap`,
  `reset-admin-password`, `reset-user-password`), which drives the documented stop-daemon → run-oneshot →
  verify-files-gone → start-daemon lifecycle, reading credentials from the terminal (or two lines on stdin) —
  never argv or environment. The proper first-run wizard is Phase 6; this is its building block. The
  bootstrap seal `/etc/casaos/recasaos-user-bootstrap.seal` is hot state and must persist with the user
  database (task 3.2).
- **UI ↔ backend mismatches found by actually logging in** (the API-level T2 passes only because it now
  speaks what the UI must speak; nobody has driven the real UI in a browser in CI yet):
  1. The UI calls `GET /v1/sys/version` right after login and treats any failure as a failed login. We had
     removed that route; it is back, answering locally (`need_update:false`, running version) — only the
     GitHub check and `POST /update`/`/stop` are gone.
  2. **No single `Authorization` form worked across the services.** The pinned UI sends the bare access token;
     the root service only accepts `Bearer <token>`; user-service takes both; app-management and message-bus
     took only the bare form. The result was a first login followed by an immediate logout (the 401s came from
     app-management/message-bus, and curl inside the machine never sees them: those services skip auth for
     loopback clients, a browser arrives through the gateway). Fixed by PR ReCasaOS-UI#11 (send `Bearer`) plus
     patches making app-management and message-bus strip an optional `Bearer ` prefix. Still open upstream:
     the wallpaper upload puts the token in a `?token=` query, which the fork rejects.
  3. user-service subscribed forever to the `local-storage` message-bus source of a service ReCasaOS does
     not ship (journal spam, 400 every second); patched out.
  All three are in `docs/upstream-exclusions.md` and are material for the ReCasaOS maintainer.
- T2 covers it end to end: status `initialized:false` → 410 on register → bootstrap → `initialized:true`,
  credential sources gone, replay rejected → login → authenticated API 200 → the removed self-update and
  self-kill routes answer 404/405.

### 3.2 — Cold/hot state boundary

**Deliverable**: a documented, implemented split — plus a `## State boundary` section appended to
this file recording the final decision table.

**The problem**: CasaOS writes its own config (`/etc/casaos/*.conf`), its databases and user data
(`/var/lib/casaos`), Samba config (`/etc/samba/smb.casa.conf`) and user accounts at runtime, from the web
UI. The base image is immutable and vendor-managed. **Resolution of principle** (AGENTS.md §2, *Cold vs hot
state* and *Baseline + include*): do not route users or shares through Nix. CasaOS already keeps hot state
in its own databases and generates config + reloads services, the way TrueNAS's middlewared does; Nix
supplies the immutable baseline and the writable places for the hot part.

**Approach to implement**

1. Classify every file CasaOS reads or writes as *cold/vendor-owned* (read-only from the store: listen
   addresses, paths, the gateway's static routing, unit files, baseline `smb.conf`) or *hot* (users,
   shares, installed apps, app-store sources, pool state).
2. Hot state lives on the writable state partition under `/var/lib/recasanix/state/` (bind- or
   symlink-mounted into the paths CasaOS expects) — databases, generated files, **and the account files
   `/etc/passwd`, `/etc/shadow`, `/etc/group`** (users are mutable). Decide the mechanism for /etc
   persistence here (bind-mount the files, or an overlay of /etc).
3. **Prefer include/override over replacement**: where a config must be both vendor-shipped and
   runtime-mutable, keep the baseline in the store and reach the mutable part through an include or
   drop-in — e.g. the store `smb.conf` gets `include = /var/lib/recasanix/state/samba/smb.casa.conf`
   (CasaOS's shares service writes that file, validates it with `testparm` and restarts smbd), systemd
   drop-ins, `conf.d/` directories. Only a config with no include mechanism gets a symlink.
4. On first boot, seed missing hot files from vendor defaults in the store; never overwrite an existing
   one. Implement this as a `recasanix-state-init.service` ordered before `casaos-gateway.service`,
   idempotent. Keep `/etc/casaos/start.d` vendor-owned (T9 pins its contents).
5. Anything vendor-owned that CasaOS nonetheless tries to write is a **finding**: record it in the
   decision table and either move it to hot state or accept a read-only failure knowingly.

**Acceptance**: after creating a user through the UI in the VM, rebuilding the system closure and
rebooting, the user still exists; and a vendor-owned file edited on disk is reverted by the rebuild.

**Verify**: test T4 (`checks.x86_64-linux.state-persistence`).

### 3.3 — Docker integration

`virtualisation.docker.enable = true`, storage driver `overlay2`, data root on the data pool
(`/var/lib/recasanix/data/docker`) so app images do not fill the small eMMC. Ship `docker-compose`
(the v2 plugin) because AppManagement invokes compose. Add a comment recording that Podman is a
later evaluation, per AGENTS.md §2.

**Acceptance**: `docker run --rm hello-world` succeeds inside the VM.

**Verify**: part of test T5.

*As built (3.3)* — `nix/modules/docker.nix` (`recasanix.docker.enable`), the `/DATA` mount in `storage.nix`, and
tests `docker` and `app-lifecycle` (T5):

- **Docker**: `virtualisation.docker` with `overlay2` (works on btrfs) and `data-root` on the pool
  (`/var/lib/recasanix/data/docker`). `docker.service` carries `ConditionPathExists` on the pool's device node, so
  **without a pool it is skipped, not failed**: the appliance boots `running` and shows its UI (where the pool
  gets created). With the pool present it is mounted first and Docker follows, including after a reboot.
- **Correction to 3.1**: app management needs *no* `docker` CLI or compose plugin on its `PATH` — it embeds the
  compose library and talks to the daemon's socket (`grep` finds no `os/exec` in it). Both entries are gone from
  its unit; the CLI is installed for operators only. T5 installs and runs an app without them.
- **`/DATA`** (`recasanix.storage.dataRoot`): app-store compose files hardcode `/DATA/AppData/$AppID/…`, and the
  root service pins `/DATA` at startup and panics if it is missing. So `/DATA` always exists on the root
  filesystem, and `DATA.mount` bind-mounts the pool's `DATA` directory over it when the pool is present (skipped,
  again by a device-node condition, otherwise — no 10 s automount wait on a diskless machine). `casaos` and
  `casaos-app-management` start after it. **Contract for the storage layer (task (b), below):** create the pool
  labelled `recasanix-data`, create `DATA` in it, start `DATA.mount` and `docker.service`, then **restart `casaos`
  and `casaos-app-management`** — the root service holds handles on the pre-mount directory. T5 does exactly
  these steps by hand.
- **Tests**: `docker` — clean boot without a pool, pool created at runtime brings Docker up on it, a container
  built with Nix runs (no registry in the sandbox), data on the pool, still there after a reboot.
  `app-lifecycle` — log in, install a compose app through AppManagement's own API (dry run, install, container
  up, listed), its data under `/DATA` on the pool, stop, start, uninstall. It preloads the image (`pull_policy:
  never`; AppManagement still tries the registry once and carries on) and does not use a local app-store stub —
  the store-driven install path (catalog download, `/apps/{id}/compose`) is **not yet covered**.
- **Finding**: AppManagement warns `cannot read symbolic link from /etc/localtime` when the file is missing;
  NixOS does not create it without `time.timeZone`. The appliance now seeds a UTC default with tmpfiles `L`
  (never overwritten), so the timezone stays operator/hot state (`timedatectl`).

---

## State boundary

*Decision record for task 3.2. The principle is in AGENTS.md §2 (cold vs hot state, baseline + include);
this is the table it produced. Implemented by `nix/modules/state.nix`, the `recasanix-state-init` service and
the bind mounts in `nix/modules/recasaos.nix`; verified by T4 (`checks.*.state-persistence`).*

**Mechanism.** One writable ext4 filesystem — the `state` partition of the image, label `recasanix-state` —
is mounted at `/var/lib/recasanix/state` **in the initrd** (`neededForBoot`), so the account restore that runs
during activation can already read it. `recasanix.state.device = null` keeps the same layout as a plain
directory on the root (throw-away development and most tests). In the development VM (`nix run .#vm`) it is a
separate persistent disk that survives VM rebuilds. **Replacing the root — what an image update does — must
lose nothing on this filesystem**, and T4 proves it by deleting the root disk between boots.

| Path | Class | Lives in | Mechanism / note |
|---|---|---|---|
| `/var/lib/casaos` (databases, per-user data, app store, apps) | hot | `state/casaos` | **bind mount**. The services' hardened storage code refuses symlinks (`open database directory component: not a directory`), so symlinks are not an option. |
| `/etc/casaos/{gateway.ini, message-bus.conf, user-service.conf, app-management.conf, casaos.conf, env}` | hot | `state/casaos-etc` (bind mounted at `/etc/casaos`) | Seeded **once** by `recasanix-state-init` from upstream's samples, never overwritten. Services write them at init and at runtime (gateway port, app-store list). The gateway seed carries `services.recasaos.httpPort`; after that the UI owns the port. |
| `/etc/casaos/recasaos-user-bootstrap.seal` | hot | same directory | Pairs with the user database (restoring one without the other is a fail-closed `recovery` state upstream). |
| `/etc/casaos/start.d` | **vendor**, executed | rebuilt every boot | The root service *runs* every script here at startup. `recasanix-state-init` deletes and recreates it with the single UI hook; T4 plants a script and asserts it is gone after reboot; T9 pins the shipped set. |
| `/var/lib/casaos/www`, `ui-message-bus.json` | vendor | store symlinks, rebuilt every boot | tampering does not persist (T4). |
| `/usr/share/casaos/shell` | vendor | store symlink (tmpfiles) | the helper scripts. |
| `/etc/passwd shadow group gshadow subuid subgid`, `/var/lib/nixos` | hot | `state/accounts`, `state/nixos` | `users.mutableUsers = true`. An activation script restores the files **before** the users activation merges the declared accounts; changes are mirrored back by a path unit on `/etc`, a 1-minute timer and a final copy at shutdown. `/var/lib/nixos` (uid/gid maps) is a symlink to state. |
| SSH host keys | hot | `state/ssh` | `services.openssh.hostKeys` points there; the device keeps its identity across updates. |
| `/var/run/casaos`, `/run/recasaos-*` | volatile | tmpfs | runtime URLs, sockets, credential drop directories of the local account units. |
| `/var/log/journal` | hot | `state/journal` (bind mount) | **log of record**: the services tee every log line to stdout → journal. Capped in `appliance.nix` (200M). Survives image updates (T4). |
| `/var/log/casaos` | volatile | root filesystem | duplicate of the journal (upstream lumberjack files: 10 MB × 60, 1 day). Lost on an image update — by design. |
| `/etc/machine-id` | hot | `state/machine-id` | restored by activation before systemd reads it; created on first boot. One identity per device: journal directory, DHCP client id. T4 asserts it across root replacement. |
| `/etc/samba/smb.conf` (baseline) + `smb.casa.conf` (generated) | baseline cold, generated hot | Nix (`smb.conf`), root service (fragment) | Nix-owned `smb.conf` with `include = /etc/samba/smb.casa.conf`; root service in include-only mode writes the fragment, validates with `testparm`, reloads smbd. Share-account passdb: `/var/lib/samba` → `state/samba` (bind mount). T13/T14. |
| Docker daemon config, Docker root | cold | Nix (task 3.3) | the API that rewrote `daemon.json` is not routed (see the register). |
| Data pool `/var/lib/recasanix/data`, `/DATA` | hot | the pool | created and mounted at runtime; unrelated to the state filesystem. |

**Findings made on the way** (kept because they will bite again):

- *Symlinks are refused* by the root service's SQLite directory checks — hence bind mounts, and the
  `dataDir`/`configDir` options are bind-mount *sources*, not link targets.
- *A path unit on a file does not see rename-replacement* (how `useradd` and friends write `/etc/passwd`): a
  user created in the running VM never reached the state filesystem, and the first version of T4 passed only
  because a boot-time mirror happened to run after `useradd`. The mirror now watches `/etc`, and T4 makes the
  boot-time mirror finish first so it can only pass on the change trigger.
- *qemu-vm replaces the whole `fileSystems` set* (again): the state mount and the bind mounts are also fed to
  `virtualisation.fileSystems`.
- *Drive order shifts device names*: the VM's state drive is appended after the blank data disk so that
  stays `/dev/vdb`; the state disk is `/dev/disk/by-id/virtio-recasanix-state`.
- Not covered yet: a *different closure* on the same state (T4 replaces the root with a fresh build of the same
  configuration; a real update would also change store paths inside seeded files — configs seeded from
  samples contain no store paths, by design).

### 3.4 — Storage manager

Added after the fact, when the VM showed the storage widget's gear (the manager) dead: the pinned ReCasaOS
has no service behind it. **Owner decision, in two steps**: a read-only storage service first, then —
immediately, once the pattern proved out — the ability to create storage on a blank disk, still on the cold/hot
model (Nix owns nothing about which disks exist; the pool is always created at runtime). Replace/degraded/scrub
and a mirror as a real UI choice stay Phase 6. Everything about it — the assessment of upstream's
CasaOS-LocalStorage (not adopted, and why), the API contract, the security properties, the known limits and the
way on to the full layer — is in [docs/storage-manager.md](./docs/storage-manager.md).

**Deliverable**: `services/recasanix-storage/` (Go, stdlib plus `golang-jwt/jwt/v4`), `nix/pkgs/recasanix-storage`,
`services.recasaos.storage`, UI patch `0004`, checks `unit-recasanix-storage` and `storage-manager` (T11).

**Acceptance**: the gear opens the panel; it lists the system volume, the pool and every disk; *Create Storage*
on a blank disk actually creates and mounts a pool the apps can use; formatting or removing an *existing*
storage is refused with a message that says so.

**Verify**: `nix build .#checks.x86_64-linux.storage-manager -L`

*As built (3.4)*:

- **A small service on the routes the UI already calls** (`/v1/disks`, `/v1/storage`, `/v2/local_storage`),
  registered with the gateway using its service token, authenticating exactly like the root service (Bearer
  ES256 JWT from the user service's JWKS, issuer `casaos`, must expire, **no loopback exemption**). Reads
  `lsblk` and `smartctl`, and — for creating — `mkfs.btrfs`/`btrfs device add`/`udevadm`/`mountpoint`/
  `systemctl`, all as argument vectors; formatting/removing an *existing* storage and merging remain
  refused with 501.
- **From scratch, not a port**: upstream's LocalStorage edits `fstab`, drives `systemctl` to enable/disable
  units, needs `udevil`, formats `ext4` only, and puts request data in `bash -c` — see the doc. Only its
  contract was taken; creating storage here is whole-disk (no partitioning) and JBOD (btrfs's default
  "single" profile) by default, matching the appliance's existing single-pool convention.
- **Every write re-validates against a fresh disk listing.** `POST /v1/storage` re-lists disks on every call
  and only proceeds on an exact match in the just-computed `avail` set — a made-up path, a partition, the
  system disk, an in-use or already-populated disk, or one below the 1 GiB minimum are all rejected before
  any command runs. `avail` itself was tightened to require a genuinely blank disk (no partition, no
  filesystem), not merely an unmounted one, on the owner's explicit instruction.
- **T11 found what unit tests could not**: with the *real* `lsblk`, the mount point of a two-disk btrfs mirror
  is reported on **one member only**, so the second member was offered as available for a new storage. Fixed
  (all members of a mounted filesystem count as in use) and covered by both the unit fixture and the VM test.
- **An upstream UI bug, patched** (`0004`): the create handler ends in `.finaly(…)`, so after any failed create
  the panel stayed on "Creation in progress" forever — found while the manager was still read-only, when every
  create failed by design; still relevant now, since a rejected create still hits that path.
- **Not verified**: how the UI displays the refusal for **Format** and **Remove** specifically (only *Create*
  is driven in a browser); a real disk's SMART data (virtual disks do not answer); a spun-down HDD
  (`--nocheck=standby` is there so as not to wake it, untested); real hardware.

---

## Phase 4 — VM and image outputs

| ID | Status | Task |
|---|---|---|
| 4.1 | [x] | `nixosConfigurations.recasanix-vm` + `packages.vm` |
| 4.2 | [x] | A/B partition layout via `image.repart` |
| 4.3 | [x] | `packages.image` hardware image |
| 4.4 | [x] | `hardware-n200.nix` stub + flashing docs |

### 4.1 — Runnable VM

**Deliverable**: `nixosConfigurations.recasanix-vm` composing appliance + storage + recasaos modules,
exposed as `packages.x86_64-linux.vm` (a `runVM` script) and `apps.x86_64-linux.vm`.

**Steps**

1. Base on the shared appliance modules plus a `vm.nix` overlay: 4 GB RAM, 4 vCPU, UEFI (OVMF),
   one blank 8 GB virtio disk for a pool (mirrors are the storage check's job, T3), and port forwards 8080→80, 2222→22.
2. Default to a graphics-less serial console so an agent can drive it headlessly.

**Acceptance**: `nix run .#vm` boots to a login prompt in under two minutes, and
`curl -fsS localhost:8080` returns HTML from the host.

**Verify**: `nix run .#vm` (manual), plus test T2 for the automated equivalent.

*As built (4.1)* — `nix/modules/vm.nix` (everything under `virtualisation.vmVariant`, so the hardware
closure is untouched) and `nix/vm-runner.nix`; `nix run .#vm` / `packages.x86_64-linux.vm`:

- 4 GB, 4 vCPU, OVMF + systemd-boot, one 8 GB virtio data disk (`/dev/vdb`, persistent), serial console,
  forwards 8080→80 and 2222→22. Measured here with KVM: login prompt after ~12 s; `curl localhost:8080`
  returns the UI, `/v1/sys/utilization` answers 401, all five units active, `systemctl is-system-running`
  is `running`, and a RAID1 pool created with `mkfs.btrfs` on the two disks is mounted by label on first use.
- With a boot loader the qemu runner no longer appends `console=` to the kernel command line, so the VM
  variant sets `console=ttyS0,115200n8` itself and `boot.loader.timeout = 0` (otherwise a silent serial
  console and a 5 s boot menu).
- Development conveniences, confined to the VM variant: ssh password login (the well-known console password
  `recasanix`; the appliance itself stays key-only). Two disks persist across runs under `~/.local/state/recasanix-vm/<checkout>-<hash>/` (one directory per clone,
  overridable with `RECASANIX_VM_DIR`): the
  root disk `recasanix.qcow2`, which the runner **resets whenever the VM definition changes** (it holds the installed
  generation and would otherwise keep booting the old one; `--fresh` resets it by hand, and `fsck.repair=yes`
  repairs it at boot if damaged), and (since 3.2) the **state disk** `recasanix-state.qcow2`
  — accounts, ReCasaOS data and config, SSH host keys — which survives VM rebuilds (delete it for a factory-fresh VM).
  The data disk `recasanix-data.qcow2` (8 GB, `/dev/vdb`) persists in the same directory, so a pool made on it
  survives runs (`--fresh-data` blanks it); the state disk is `/dev/disk/by-id/virtio-recasanix-state`.
- Quit QEMU with `Ctrl-A x`.
- First login: create the administrator inside the VM with `recasanix-user-admin bootstrap` (see 3.1 notes).

### 4.2 — A/B partition layout

**Deliverable**: `nix/modules/image.nix` using the `image.repart` NixOS module
(`nixos/modules/image/repart.nix`).

Layout — A/B-capable now, RAUC-ready later (AGENTS.md §2):

| # | Partition (GPT name) | Type | Size | Notes |
|---|---|---|---|---|
| 1 | `recasa-esp` | EFI System | 512 MiB | systemd-boot + the UKI of the running slot |
| 2 | `recasanix-root-a` | root-x86-64 | 8 GiB | ext4, populated by this build |
| 3 | `recasanix-root-b` | root-x86-64 | 8 GiB | created empty, reserved for the RAUC phase; fixed UUID |
| 4 | `recasanix-state` | linux-generic | 4 GiB | ext4, created by the image build; hot state (`recasanix.state`) |
| 5 | `recasanix-data` | own type UUID | grows | **blank**; grown to the end of the disk on first boot |

**Decisions taken while building it** (they differ from the first draft of this task):

- **The data partition is not formatted.** The draft said "btrfs data pool", but pools are hot state
  and always created at runtime (`nix/modules/storage.nix` never formats anything). The image only
  guarantees that the eMMC's remaining space is a partition of its own; the runtime storage layer
  creates the pool on it (`mkfs.btrfs -L recasanix-data /dev/disk/by-partlabel/recasanix-data`).
- **The data partition has its own type UUID** rather than `linux-generic`. Repart matches existing
  partitions to its definitions by type, so a second `linux-generic` partition beside `state` would
  make the first-boot growth ambiguous.
- **The root is named, not discovered.** Two `root-x86-64` partitions make GPT auto-discovery
  ambiguous, so `fileSystems."/"` points at `recasanix-root-a`. Slot switching is the RAUC phase.
- **Slot A only on the ESP.** The UKI is placed on the ESP by the image build (there is no
  installer on a device that is only flashed); the RAUC phase adds the second slot's UKI there.

**Steps**

1. Define partitions with `image.repart.partitions`; give both root slots explicit, stable UUIDs
   and identical fixed sizes, so a bundle that fits one fits the other.
2. Enable `boot.initrd.systemd.repart` with `device = null`: repart then operates on whichever disk
   backs the root filesystem, so no device name (eMMC, NVMe, SATA, QEMU) is baked in. Only the data
   partition has a runtime definition, so nothing else is touched.
3. Do not add verity or RAUC config. Leave a commented block naming the two follow-ups
   (`repart-verity-store.nix` for verity; a `rauc` system.conf for slot definitions) so the next
   phase is obvious.

**Acceptance**: the built image has exactly five partitions with the intended types and sizes.

**Verify**:
```sh
nix build .#image
sfdisk -J result/*.raw | jq -r '.partitiontable.partitions[] | "\(.name) \(.type) \(.size)"'
```

### 4.3 — Hardware image output

`packages.x86_64-linux.image` = the repart image for the N200 board, built from its own machine,
`nixosConfigurations.recasanix-image` (`nix/hosts/recasanix-image.nix`). Unlike `recasanix-vm` it carries no
development conveniences: no well-known password, no port forwards, no placeholder root. SSH is
key-only and the image ships no password, so the keys in `nix/hosts/admin-authorized-keys` are the
only way in — see `docs/flashing.md`, which also covers the flashing invocation, the UEFI settings to
check, and creating the data pool.

**Acceptance**: the image boots in QEMU with OVMF from the same artifact that would be flashed —
i.e. test T6 boots `packages.image`, not a separate VM-only build.

`nix run .#emulate-image` (`nix/image-runner.nix`) does the same by hand, interactively: it copies the
image to a scratch disk (default `/tmp/recasanix-image`, refusing to start if the filesystem lacks the
space), enlarges it, keeps it and the firmware's variable store between runs, attaches one blank SATA
data disk (sparse file; there is no pool on the image, so making one needs a disk), and forwards the web
UI (8081) and SSH (2223) on loopback. See [TESTING.md](./TESTING.md).

### 4.4 — Hardware stub

`nix/modules/hardware-n200.nix`: firmware (`hardware.enableRedistributableFirmware`), Intel
microcode, `kernelModules` for the board's NICs/SATA once known, and a TODO list for LEDs, fan
control and disk-bay identification (called out in the Shanwei direction note as the likely custom
work). Keep it importable and near-empty until hardware arrives. (Built: it holds the generic Intel
firmware, microcode and initrd storage/USB modules the image needs to find its root, plus the TODO
list.)

---

## Phase 5 — Test strategy

Tests are flake checks, so `nix flake check` is the single entry point (AGENTS.md §2: local now,
GitLab CI later). All of these must run without hardware.

| ID | Status | Check | Kind |
|---|---|---|---|
| T1 | [x] | `checks.<sys>.unit-<component>` | Upstream Go unit tests per component |
| T2 | [x] | `checks.<sys>.recasaos-boot` | NixOS VM test: services up, UI served |
| T3 | [x] | `checks.<sys>.storage` | NixOS VM test: single + mirror pool |
| T4 | [x] | `checks.<sys>.state-persistence` | NixOS VM test: state survives a rebuild |
| T5 | [x] | `checks.<sys>.app-lifecycle` | NixOS VM test: Docker + install an app |
| T6 | [x] | `checks.<sys>.image-boots` | Boot the real image artifact under OVMF |
| T7 | [x] | `checks.<sys>.pin-drift` | Pins match upstream `components.lock.json` |
| T8 | [x] | `checks.<sys>.lint` | `statix` + `deadnix` + `nixfmt --check` |
| T9 | [x] | `checks.<sys>.no-host-management` | Guardrail: no host-management machinery in the closure |
| T10 | [x] | `checks.<sys>.ui-login` | Headless Chromium logs into the real UI and must stay logged in (no 401s) |
| T11 | [x] | `checks.<sys>.storage-manager` | Real VM + gateway + UI in a browser: lists disks/volumes, creates storage on a blank disk (UI, then API for JBOD-extend), refuses changes to an existing one, needs a real access token |
| T12 | [x] | `checks.<sys>.service-auth` | NixOS VM test: service-to-service trust boundary (loopback is not an identity) + UI power-off reaches systemd |
| T13 | [x] | `checks.<sys>.smb-shares` | NixOS VM test: Samba with Nix-owned smb.conf, share accounts via the API, real smbclient: owner in, others/guests/wrong password out; fragment regenerated; survives a reboot |
| T14 | [x] | `checks.<sys>.smb-ui` | Headless Chromium: Files → Shared → Share accounts → add; right-click a folder → Share → only that account; API, ownership and smbclient agree |

### T1 — Component unit tests

Run each Go component's own `go test ./...` in a derivation separate from the build derivation
(`<pkg>.tests` or `checks.unit-casaos-gateway`). Separation matters: an upstream test needing
network or root must not block the image build. Mark such tests skipped with a recorded reason
rather than deleting them. For `casaos-ui`, run `pnpm test` (vitest) the same way.

**Verify**: `nix build .#checks.x86_64-linux.unit-casaos-gateway -L`

### T2 — Service boot test (the primary integration test)

`pkgs.testers.runNixOSTest`, one machine using the real appliance modules:

```python
machine.wait_for_unit("casaos-gateway.service")
machine.wait_for_unit("casaos-message-bus.service")
machine.wait_for_unit("casaos.service")
machine.wait_for_unit("casaos-user-service.service")
machine.wait_for_unit("casaos-app-management.service")
machine.wait_for_open_port(80)
machine.succeed("curl -fsS http://localhost/ | grep -qi '<html'")
# the fork's hardening must still be in force
machine.succeed("systemctl show casaos-user-service.service -p UMask | grep -q 0077")
```

Add an API-level assertion once the gateway's route file is understood (hit a known
`/v1/...` endpoint and assert a non-5xx response).

Because the shell helpers resolve their interpreter and tools from the unit's `PATH` at runtime
(task 3.1.2), an incomplete `path` is invisible at build time. Assert it explicitly:

```python
# the helpers must be runnable in the service's own environment, not just present on disk
machine.succeed(
    "systemctl show casaos.service -p Environment | grep -q PATH="
)
machine.succeed(
    "systemd-run --wait --pipe --same-dir --service-type=oneshot "
    "-p 'Environment=PATH=$(systemctl show casaos.service -p Environment)' "
    "/run/current-system/sw/share/casaos/shell/helper.sh GetSysInfo"
)
machine.fail("journalctl -u casaos.service | grep -q 'command not found'")
```

Adjust the invocation to however the module installs the helpers; the point is that the assertion
runs a helper *in the service's environment* and fails on an unresolved command.

### T3 — Storage test

Four machines, driven with `virtualisation.emptyDiskImages`. The pool is created **inside the test with
`mkfs.btrfs`** — as the runtime layer will — and found by label: diskless and blank-disk machines boot
with nothing failed (blank disks left untouched, the mountpoint unusable rather than silently writing to
the root device); a single-device pool mounts on first access and survives a reboot; a two-device
mirror reports `RAID1` in `btrfs filesystem df`, and pulling one device (virtio-blk has no SCSI
`device/delete`; the test removes the PCI function: `echo 1 > $(readlink -f
/sys/block/vdc/device/..)/remove`) leaves the pool readable with the degradation visible in the journal
(btrfs kernel messages; smartd has no SMART data in a VM). Note `mountpoint` is true for an untriggered
automount; the test asks `findmnt -t btrfs` for a real mount.

### T4 — State persistence test

Exercises the phase-3.2 boundary, which is the design's highest-risk area:

1. Boot, write a user-owned artifact (create a user via the CasaOS API, or touch the file the UI
   would write).
2. `machine.shutdown()`, restart with the same state disk but a *different* system closure
   (`nodes.machine.specialisation` or a second `system.build.toplevel` switched into).
3. Assert the user-owned artifact survives and a deliberately modified vendor-owned file is back to
   its store content.

### T5 — App lifecycle test

`docker run --rm hello-world`, then drive AppManagement's API to install a small compose app from a
locally served app-store stub (do not hit the public CasaOS app store in a test). Assert the
container ends up running and the app's data lands on the data pool, not on the root filesystem.

### T6 — Image boot test

Boot `packages.image` itself under QEMU + OVMF (`nix/tests/image-boots.nix`), as it would be flashed:
an NVMe disk and an Intel NIC (the board's kind of hardware, not virtio), nothing added for testing.
This is what catches partition-layout and bootloader mistakes that a `nixos-rebuild`-style VM test
cannot.

It is a plain QEMU run, **not** a `runNixOSTest` as first planned: the NixOS test driver needs a
backdoor service inside the guest, which would make the machine under test a different system from the
one that ships. The test sees only what a user sees — the serial console, the web UI, and the disk
afterwards. The image is copied onto a 32 GiB disk (larger than the image) and booted. Asserted:

- the web UI answers and the serial console reaches the `recasanix login:` prompt;
- after a clean power-off, exactly five partitions with the intended types and sizes, and `root-b`
  keeping its stable UUID;
- the data partition **grew** to fill the disk (512 MiB in the image → ~11.5 GiB);
- `root-b` is still entirely zero;
- hot state landed on the state partition (SSH host key and the account mirror, read with `debugfs`).

Needs KVM (`requiredSystemFeatures = [ "kvm" ]`); takes about 40 seconds.

**Verify**: `nix build .#checks.x86_64-linux.image-boots -L`

### T7 — Pin drift check

A trivial derivation comparing `nix/pins/components.lock.json` against the flake input revs. Fails
loudly when someone bumps one input without the others — the exact failure mode the pinning decision
exists to prevent. (A network fetch of the upstream lock belongs in a scheduled CI job later, not in
`nix flake check`.)

### T8 — Lint

`statix check`, `deadnix --fail`, `nixfmt --check` over the tree as one check derivation.

### T9 — Host-management guardrail

Mechanical enforcement of the cross-cutting guardrail above — the point where vigilance stops
depending on whoever reviews the next upstream bump.

Two halves:

1. **Closure scan.** Over `casaos-sysroot` and the built system's `/etc` + `/share`, fail on any
   surviving distro-lifecycle path or package-manager call:

   ```sh
   # excluded paths must not reappear after an upstream bump
   test ! -e "$sysroot/usr/share/casaos/cleanup"
   ! grep -rlE '\b(apt-get|apt|dpkg|pacman|yum|dnf)\b' "$sysroot"
   ! grep -rlE 'systemctl +(enable|disable|daemon-reload)' "$sysroot"
   ```

2. **Register completeness.** Every path the derivations exclude must have a row in
   `docs/upstream-exclusions.md`, and every row must name whether its caller (route, UI) was
   disabled. Drive both from one list in `nix/lib/exclusions.nix` so the derivation, the check and
   the register cannot drift apart.

Make the failure message name the offending path *and* point at the guardrail section — the agent
hitting this check months from now needs to know it is a deliberate policy, not a packaging bug.

**Verify**: `nix build .#checks.x86_64-linux.no-host-management -L`

### T10 — UI login (real browser)

`nix/tests/ui-login.{nix,py}`: after the local bootstrap, a headless Chromium (Playwright) on the test
driver opens the UI through a forwarded port, logs in, waits 20 s and asserts it is still logged in with a
token in localStorage and **no 401 in the request log**. It exists because API checks made with curl from
inside the machine cannot see integration breaks: app-management and message-bus skip authentication for
loopback clients, a browser arrives through the gateway (see "UI ↔ backend mismatches" in 3.1). Needs
~450 MB of browser closure and DejaVu fonts (Chromium aborts without a fontconfig); the form is filled
from inside the page because the login layout re-renders while it settles.

### T11 — Storage manager (VM, API and real browser)

`nix/tests/storage-manager.nix` (+ `storage-panel.py`): a VM with the real gateway, user service, UI and
Docker, two blank 2 GiB disks and the real `lsblk`/`smartctl`/`btrfs-progs`. It asserts, in order:

- **authentication**: no token, garbage, and a **refresh token** (a valid JWT from the same user service) are all
  401 on every route, `POST /v1/storage` included;
- **the inventory**: the two blank disks are `avail` and need formatting, the system disk is `System`, the
  system volume is at `/`, virtual disks that do not answer SMART do not look failing, and the lists are lists
  (never `null`: the UI iterates them);
- **changes to an *existing* storage are refused**: `PUT/DELETE` on storage, `DELETE` on disks/USB and the v2
  mount/merge routes all answer 501 saying so, and `lsblk` is identical afterwards;
- **creating is rejected up front** for a made-up path, the system disk, and `format:false` — none of it
  touches a disk, and the root mount is unchanged;
- **the real UI creates the first storage** (headless Chromium): the gear, the form, *Format and create*, a
  **success** toast ("All Storage successed to be created." — upstream's own typo), the panel not stuck on
  "Creation in progress" (UI patch `0004`), and `/dev/vdb` really is `recasanix-data` and mounted afterwards;
- **the API extends the same pool with the second disk** (JBOD): listed once at `/DATA`, `btrfs`, sizes as
  digit strings, `persisted_in: fstab`, `btrfs filesystem df` shows `single` (not `raid1`), two `devid` lines,
  neither disk is `avail` any more, and DATA/docker/casaos are all active;
  re-creating on the now-used `/dev/vdb` is rejected and the pool's UUID is unchanged;
- **the real UI, again**: now shows the pool;
- **the service itself**: no errors in its journal, no restarts, `NoNewPrivileges`/`ProtectSystem` in force, and
  it **registers again after the gateway restarts** and forgets its routes.

The unit tests (`unit-recasanix-storage`) cover the parsing, mapping, SMART, authentication (every way a token can
be wrong, algorithm confusion included), the gateway logic and creating storage (both branches, every step's
failure, argument-vector shape) against fixtures, and were mutation-checked: breaking the issuer check, the
expiry requirement, the mirror rule, the blank/size requirements on `avail`, or always-format-never-extend all
fail them.

### T12 — Service-to-service trust boundary

`nix/tests/service-auth.nix`. Loopback is not an identity: any local process, and any container on the host
network, reaches the services' listeners. The message bus and app management skip the user token only for an
in-stack caller — the gateway's per-start service credential (`/run/casaos/gateway.token`, root `0600`) from
loopback, or a connection that really arrived on the bus's root-only unix socket. Asserts:

- every in-stack registrant (root, user service, app management, the UI's start.d script) still registers its
  event types, and the bus logged no 401;
- loopback without / with a wrong credential, `Host: unix` (direct, through the gateway, and from the LAN
  address — pinned upstream answered **200 with every event type** there), and the socket as `nobody` are refused;
- a browser's WebSocket subscription needs a one-use ticket (`POST /v2/message_bus/ticket` sets an HttpOnly,
  SameSite=Strict cookie the handshake redeems): none → 401, ticket → 101, replay → 401 (PRs
  ReCasaOS-MessageBus#6, ReCasaOS-MessageBus#7; dashboard side ReCasaOS-UI#10, asserted by T10, which requires frames on the socket.io
  subscription);
- `PUT /v1/sys/state/off` ends in a `systemctl poweroff` requested by `casaos.service`, and the VM powers off.

Code: upstream PRs to EdmundFu-233 (list + order: [COMPARISON-FORKS.md](./COMPARISON-FORKS.md)), built from
our forks' preview branches until merged (AGENTS.md §2, "ReCasaOS pinning").

### T13 — Network shares

`nix/tests/smb-shares.nix`, decisions in AGENTS.md §2 ("SMB"). Samba runs with a Nix-owned `smb.conf`
(SMB2+, mandatory signing, `map to guest = never`, `include = /etc/samba/smb.casa.conf`); the root service
runs in include-only mode and publishes only that fragment, regenerated from its share database at every
start (so the fragment is derived state; the database and Samba's passdb are on the state partition).
Asserts, with a real `smbd` and `smbclient`: share accounts are created through the API with a nologin
shell and never touch system accounts (root cannot be enrolled); a share restricted to an account lets
that account in and gives it the files, refuses other accounts, guests and wrong passwords; an account in
use cannot be deleted; deleting the fragment and restarting the root service restores it; accounts and
passwords survive a reboot; re-assigning or removing the share hands the directory over / back to root.
Upstream: ReCasaOS#153, #154 (merged). Discovery: `samba-wsdd` (Windows) and avahi (mDNS).
T14 (`nix/tests/smb-ui.{nix,py}`) drives the same through the dashboard (PRs ReCasaOS-UI#8, ReCasaOS-UI#9). It needs
a data pool: without Docker, app management answers the app grid with 500 and the upstream dashboard drops
the whole grid, the built-in Files app included (an upstream UI robustness bug, not fixed here).

### Running tests

```sh
nix flake check -L                                  # everything
nix build .#checks.x86_64-linux.recasaos-boot -L    # one test
nix run .#checks.x86_64-linux.recasaos-boot.driverInteractive   # interactive debugging
```

VM tests need KVM (`/dev/kvm` present and writable). Note this in the README when CI is set up.

---

## Phase 6 — Deferred (explicitly out of scope for the prototype)

Recorded so nobody picks them up early, and so the phase-1 work stays shaped for them.

| Topic | Note |
|---|---|
| RAUC integration | Daemon, `system.conf` slot definitions, signed `.raucb` bundle as a Nix derivation, systemd-boot slot switching, delta transport. Layout from 4.2 is the prerequisite. |
| dm-verity | `repart-verity-store.nix` exists in nixpkgs. Decide after RAUC works. |
| CI + binary cache | A CI pipeline with a KVM-capable Nix runner; a substituter so devices/CI do not rebuild. |
| Podman evaluation | Re-test app-store compatibility against `virtualisation.podman.dockerCompat`. |
| ZFS variant | Commented block from 2.1; flip and run T3 against it. |
| Signing infrastructure | Cert chain and key rotation for RAUC bundles. |
| **Storage layer (owner decision (b))** | **Targeted for the first release in more or less full functionality — revisit its maturity in time; do not let the prototype's by-hand steps stand in for it.** *Task 3.4 already covers listing, and creating a new pool or extending it (JBOD, whole-disk, single-profile). What remains here*: **repair/replace a disk, a mirror (or converting single→raid1) as a real UI choice**, `degraded` mount as an explicit operation, format/remove an *existing* storage, surface SMART and scrub state, later removable media (deferred, reinstated as native units) — on the same routes, same validate-against-a-fresh-listing discipline, same argument-vector-only rule. Tests: extend `storage-manager.nix` (T11) rather than starting a new suite — it already has the fixtures, the token flow and the browser wiring. |
| First-run UX | Setup wizard, factory reset. |
| SMB/shares hardening | Upstream's SMB-credential admission units are shipped but unexercised by tests. |
