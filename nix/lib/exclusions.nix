{ lib }:
# The upstream-exclusions list — see the cross-cutting guardrail in DEVELOPMENT.md.
#
# One list drives three consumers so they cannot drift apart:
#   * the derivations (`installSysroot` below drops the listed sysroot paths and *fails* when a
#     listed path no longer exists upstream),
#   * check T9 (`checks.*.no-host-management`), which re-verifies the installed sysroot and that
#     docs/upstream-exclusions.md is exactly `register` rendered from this file,
#   * the human-readable register itself (docs/upstream-exclusions.md is generated from `register`;
#     refresh it with `nix build .#exclusions-register && install -m644 result docs/upstream-exclusions.md`).
#
# Entry kinds:
#   path     — file/directory not shipped; paths under build/sysroot/ are removed from the installed
#              sysroot, others (build/scripts/…) are simply never installed. Existence is asserted.
#   patch    — source or script patched to remove a caller or a host-management function. The patch
#              lives in nix/pkgs/<component>/patches/ and fails to apply loudly on an upstream bump.
#   pr       — fixed by an upstream PR; built from our fork's staging branch until merged
#              (nix/pins/staging.json, nix/pins/update.sh), then plain upstream.
#   finding  — spotted, not shipped or not reachable, recorded for review (may carry a TODO).
#
# `caller` states whether the route / UI affordance / script function that invoked the excluded
# thing has been disabled. Start it with "n/a", "yes" or "TODO".
let
  common = "build/sysroot/usr/share/casaos";

  # Machinery every Go service repo carries in the same shape.
  perService =
    {
      name, # cleanup/setup/migration directory name, e.g. "gateway"
      buildroot ? false,
    }:
    [
      {
        path = "build/scripts/setup";
        kind = "path";
        why = "Distro installer scripts (debian/arch setup-${name}.sh) that write /etc, enable and start units and call package managers.";
        replacedBy = "The NixOS module (task 3.1) declares units and config.";
        caller = "n/a — only run by the upstream installer, which is not packaged";
      }
      {
        path = "build/scripts/migration";
        kind = "path";
        why = "In-place migration of a mutable Debian host between CasaOS versions.";
        replacedBy = "Image rebuilds replace the system closure; state layout is task 3.2.";
        caller = "n/a — only run by the upstream installer, which is not packaged";
      }
      {
        path = "${common}/cleanup";
        kind = "path";
        why = "Uninstall hooks (debian/arch cleanup-${name}.sh) that stop/disable units and remove files from a mutable host.";
        replacedBy = "Nothing: the appliance is not uninstalled piecemeal; an image replaces the closure.";
        caller = "n/a — only run by the upstream installer, which is not packaged";
      }
    ]
    ++ lib.optional buildroot {
      path = "build/sysroot/usr/lib/systemd/system/casaos-${name}.service.buildroot";
      kind = "path";
      why = "Alternative unit for Buildroot images (different ExecStart flags); not a loadable unit name. Note the app-management variant passes --removeRuntimeIfNoNvidiaGPU, which rewrites the Docker daemon runtime config.";
      replacedBy = "systemd.services.casaos-${name} in the NixOS module (task 3.1).";
      caller = "n/a — never loaded by systemd";
    };
in
rec {
  components = {
    casaos-gateway = perService {
      name = "gateway";
      buildroot = true;
    };
    casaos-message-bus = perService { name = "message-bus"; } ++ [
      {
        path = "service/{event,action}_service_websocket.go: Start / Publish / Trigger";
        kind = "pr";
        why = "Not host management — startup races: a subscription made before Start (YSK, right after Services.Start) was dropped by Start's map reset; Publish/Trigger before Start dereferenced a nil context.";
        replacedBy = "Start keeps the subscriber map; Publish/Trigger drop until Start ran.";
        caller = "n/a — branch fix/subscriptions-before-start (ppenguin/CasaOS-MessageBus-RCOS), in staging";
      }
    ];
    casaos-user-service = perService { name = "user-service"; } ++ [
      {
        path = "route/v1/user.go: GET /v1/users/status register key, POST /v1/users/register";
        kind = "pr";
        why = "Not host management — security: an empty box hands a register key to anyone asking, so the first visitor on the LAN becomes administrator.";
        replacedBy = "`[app] FirstAdmin = local` (set by recasanix-state-init): no key, register → 403; first administrator via `casaos-user-service -bootstrap-admin` with systemd credentials (recasanix-user-admin bootstrap). `-ru` (reset-password) now ends the process and needs no gateway.";
        caller = "yes — the welcome page says the account is made on the machine (UI branch feat/image-managed-host). Branch feat/local-first-admin (ppenguin/CasaOS-UserService-RCOS), in staging";
      }
      {
        path = "main.go: go route.EventListen()";
        kind = "patch";
        why = "Subscribes to the bus source `local-storage` of CasaOS-LocalStorage, which ReCasaNix does not ship (recasanix-storage serves the storage widget instead). Nothing registers the source: 1000 dial attempts, one per second, journal noise only.";
        replacedBy = "Nothing; the events it would persist do not exist.";
        caller = "n/a — no UI or API depends on it. patches/0001-drop-local-storage-listener.patch (local: upstream ships LocalStorage)";
      }
    ];
    casaos-app-management =
      perService {
        name = "app-management";
        buildroot = true;
      }
      ++ [
        {
          path = "route/v1/docker.go: PutDockerDaemonConfiguration";
          kind = "finding";
          why = "Rewrites /etc/docker/daemon.json, then `systemctl daemon-reload`, stop and start of docker.service from an API call.";
          replacedBy = "virtualisation.docker settings and data-root on the data pool (task 3.3).";
          caller = "yes — route registration is commented out upstream (route/v1.go). Re-check on every bump.";
        }
        {
          path = "route/v2.go: git-deployed apps (/v2/app_management/git/*, webhook)";
          kind = "finding";
          why = "Apps built from a git repository on the box: host `git` and `docker build`, plus a webhook route that skips the JWT (HMAC-signed by the app's secret).";
          replacedBy = "Nothing: hidden for now (owner decision 2026-10-23). `git` is not on the unit's PATH, so a git app created through the API alone fails to clone; the webhook has no app to build.";
          caller = "yes — the dashboard's only entry ('From a git repository…' in the app menu) is removed: casaos-ui patches/0001-hide-git-apps.patch. Routes stay (no app exists to reach them)";
        }
      ];
    casaos = perService { name = "casaos"; } ++ [
      {
        path = "${common}/shell/update.sh";
        kind = "path";
        why = "Upstream self-update entry point (curl the installer, run it as root).";
        replacedBy = "Image/OTA pipeline (RAUC, later phase).";
        caller = "yes — no Go code runs it; the update routes are absent in image-managed mode (below)";
      }
      {
        path = "${common}/shell/smb-discovery.sh";
        kind = "path";
        why = "Installs and configures discovery on a Debian host (wsdd, avahi service files, smb.conf edits).";
        replacedBy = "services.samba-wsdd + avahi + Samba with mDNS, declared in the NixOS module.";
        caller = "n/a — run by the upstream installer only";
      }
      {
        path = "build/sysroot/etc/casaos/smb-discovery.conf.sample";
        kind = "path";
        why = "Configuration of smb-discovery.sh (above).";
        replacedBy = "Nix (as above).";
        caller = "n/a";
      }
      {
        path = "build/sysroot/usr/lib/systemd/system/casaos-wsdd.service";
        kind = "path";
        why = "wsdd unit of the upstream installer (`/bin/bash`, PartOf=smbd).";
        replacedBy = "services.samba-wsdd.";
        caller = "n/a — never loaded (the module declares its own units)";
      }
      {
        path = "route/v1.go: /v1/sys/{os,os/*,update,autoupdate,packages*,docker/containers,docker/update*,modules*,stop}";
        kind = "pr";
        why = "Host management through the API: OS upgrade (apt), release self-update (installer as root), automatic updates, apt and Docker package updates, optional modules (apt + archive download + unit enable), self-kill.";
        replacedBy = "`[server] ImageManaged = true` (set by recasanix-state-init): routes not registered (404 = core without the feature → the dashboard shows none of it), no network version check, no auto-update loop, no new-release / OS-support alerts. Branch feat/nixos-host (ppenguin/CasaOS-RCOS), in staging.";
        caller = "yes — UI: package row hidden, update row says 'Updated with the system image' (UI branch feat/image-managed-host). The `casaos module` CLI subcommand stays in the binary (root only, no API path)";
      }
      {
        path = "pkg/telemetry: anonymous statistics (PostHog), on by default";
        kind = "finding";
        why = "Phone-home: a heartbeat every three hours with a box id.";
        replacedBy = "recasanix-state-init writes /var/lib/casaos/telemetry-off on every boot; the core folds it into its state at start.";
        caller = "TODO — the dashboard switch (GET/PUT /v1/sys/telemetry) can still turn it on until the next restart; decide: hide the switch or accept";
      }
      {
        path = "${common}/shell/helper.sh: DockerImgMove, PackageDocker, SetLink, TarFolder, USB_Start_Auto, USB_Stop_Auto, EditSmabaUserPassword, AddSmabaUser, ReloadSamba";
        kind = "patch";
        why = "Functions that rewrite /etc/docker/daemon.json, stop docker, enable/disable devmon units, create host users with useradd/smbpasswd, call /etc/init.d/smbd, or delete symlinks under /DATA.";
        replacedBy = "Nothing is needed: no caller. Docker runtime setup is cold-layer Nix (task 3.3); users and shares are hot state owned by the CasaOS services, not by host scripts.";
        caller = "n/a — called from Go: GetDeviceTree, CatNetCardState, GetNetCard, GetTimeZone, GetSysInfo, RestartSMBD, MountCIFS only. Patch: patches/0001-helper-strip-host-management.patch";
      }
      {
        path = "${common}/shell/{helper,usb-mount}.sh: absolute /bin/* paths";
        kind = "patch";
        why = "/bin/rm, /bin/rmdir, /bin/kill: NixOS has no /bin beyond sh. The prefix is deleted so the unit's PATH resolves the command (AGENTS.md §5).";
        replacedBy = "systemd.services.casaos.path (task 3.1).";
        caller = "n/a";
      }
      {
        path = "CasaOS-Common utils/command OnlyExec; ${common}/shell/*.sh shebangs: /bin/bash";
        kind = "pr";
        why = "Absolute /bin/bash does not exist on NixOS: every helper.sh call (OnlyExec) and every script run by its shebang would fail.";
        replacedBy = "OnlyExec runs `bash` from PATH (CasaOS-Common fix/bash-from-path; the root builds against our Common staging through a go.mod replace until released); shebangs `#!/usr/bin/env bash` (feat/nixos-host).";
        caller = "n/a";
      }
      {
        path = "route/*.go (all services): Authorization token lookup";
        kind = "pr";
        why = "Not host management — interoperability: every service took the whole Authorization value as the JWT, so the standard `Bearer <token>` (RFC 6750; OpenAPI `bearer`, curl `--oauth2-bearer`) was a 401. Bare token = CasaOS heritage, kept (owner decision 2026-10-23: tolerant reader, no breaking change).";
        replacedBy = "CasaOS-Common `jwt.TokenFromAuthorization` (bare or `Bearer`, case-insensitive; other schemes untouched) used by root, gateway, user service, app management, message bus. Branches feat/bearer-authorization (ppenguin/*-RCOS), in staging; services build against our Common staging until released.";
        caller = "n/a — the dashboard keeps sending the bare token";
      }
      {
        path = "service/shares.go: smb.conf ownership, smbd restart on every share edit";
        kind = "pr";
        why = "The core moves and rewrites /etc/samba/smb.conf (a read-only store link on NixOS) and restarts smbd on every share change, dropping every session.";
        replacedBy = "`[server] SambaMainConfig = external` (include-only: Nix owns smb.conf, the core writes and regenerates only smb.casa.conf at every start); share edits reload smbd and close only the edited shares (fix/samba-reload, feat/nixos-host). `smbd.service` is an alias of samba-smbd.service.";
        caller = "yes — exercised by check smb-shares (T13)";
      }
      {
        path = "main.go: command.ExecuteScripts(/etc/casaos/start.d)";
        kind = "finding";
        why = "Executes every script in /etc/casaos/start.d at startup — arbitrary code execution from a config directory. The one legitimate occupant is the UI's register-ui-events.sh (registers UI event types with the message bus; `#!/bin/sh`, needs curl and logger on the unit's PATH).";
        replacedBy = "T9 asserts the shipped start.d holds only register-ui-events.sh; recasanix-state-init rebuilds it on every boot, so a persistent tamper cannot survive (T4).";
        caller = "TODO — kept deliberately (needed for UI events); vendor-owned and rebuilt each boot (task 3.2)";
      }
      {
        path = "${common}/shell/usb-mount@.service, usr/lib/systemd/system/rclone.service";
        kind = "finding";
        why = "Upstream units the NixOS module does not define: the udev-triggered removable-media template hardcodes /casaOS/server/shell and /DATA/USB_Storage_*, and rclone backs cloud-drive mounting. Both stay in the sysroot as inert files.";
        replacedBy = "rclone: dropped (cloud-drive mounting is not a product feature). Removable media: to be reinstated as a NixOS-native template unit and udev rule (deferred).";
        caller = "TODO — until removable media is reinstated the UI's USB affordance is non-functional";
      }
      {
        path = "cmd/migration-tool, cmd/message-bus-docgen";
        kind = "finding";
        why = "Each repo builds a migration-tool binary that drives systemctl on a Debian host.";
        replacedBy = "Not built: derivations use explicit subPackages.";
        caller = "n/a";
      }
    ];
    casaos-ui = [
      {
        path = "src/components/Apps/AppSection.vue: 'From a git repository…'";
        kind = "patch";
        why = "Entry to git-deployed apps (clone + build on the box, webhook-triggered redeploys): not offered on the appliance for now.";
        replacedBy = "Nothing (owner decision 2026-10-23); see the app-management entry.";
        caller = "yes — menu item removed: patches/0001-hide-git-apps.patch";
      }
      {
        path = "src/components/TopBar.vue: update row, System packages row; src/views/Welcome.vue";
        kind = "pr";
        why = "In-place update, apt package updates and web registration of the first account are host management / unsafe on an image-managed appliance.";
        replacedBy = "Rows follow the core: automatic updates, modules and the OS badge appear only where the core answers (absent in image-managed mode); package row hidden and update row reads 'Updated with the system image' on `image_managed`; welcome page says the first account is made on the machine on `first_admin: local`. Branch feat/image-managed-host (ppenguin/CasaOS-UI-RCOS), in staging.";
        caller = "yes";
      }
    ];
  };

  # Paths (relative to the component's source root) that are excluded from the sysroot or asserted.
  pathsOf = name: map (e: e.path) (lib.filter (e: e.kind == "path") (components.${name} or [ ]));

  sysrootPrefix = "build/sysroot/";

  # Shell snippet for a derivation's installPhase, run from the (patched) source root.
  installSysroot =
    name:
    let
      paths = pathsOf name;
      shipped = map (lib.removePrefix sysrootPrefix) (lib.filter (lib.hasPrefix sysrootPrefix) paths);
    in
    ''
      for p in ${lib.escapeShellArgs paths}; do
        if [ ! -e "$p" ]; then
          echo "ERROR: excluded path '$p' no longer exists upstream (${name})." >&2
          echo "       Upstream renamed or moved it. Re-run the host-management audit (DEVELOPMENT.md," >&2
          echo "       'Cross-cutting guardrail') and update nix/lib/exclusions.nix." >&2
          exit 1
        fi
      done
      mkdir -p "$out/share/casaos-sysroot"
      cp -r --no-preserve=ownership build/sysroot/. "$out/share/casaos-sysroot/"
      for p in ${lib.escapeShellArgs shipped}; do
        rm -rf "$out/share/casaos-sysroot/$p"
      done
      chmod -R u+w "$out/share/casaos-sysroot"
    '';

  # docs/upstream-exclusions.md, rendered.
  register =
    let
      esc = s: lib.replaceStrings [ "|" ] [ "\\|" ] s;
      row =
        comp: e:
        "| `${comp}` | `${esc e.path}` | ${e.kind} | ${esc e.why} | ${esc e.replacedBy} | ${esc e.caller} |";
      rows = lib.concatLists (lib.mapAttrsToList (comp: es: map (row comp) es) components);
    in
    ''
      # Upstream exclusions register

      <!-- GENERATED from nix/lib/exclusions.nix — do not edit by hand.
           Refresh: nix build .#exclusions-register && install -m644 result docs/upstream-exclusions.md
           Enforced by check T9 (checks.<sys>.no-host-management). -->

      Everything in ReCasaOS that assumes it owns a mutable Debian host and that ReCasaNix therefore
      does not ship, together with the callers that were cut. See the *Cross-cutting guardrail*
      section of [DEVELOPMENT.md](../DEVELOPMENT.md) for the policy; this file is the review artefact
      for upstream bumps and for the conversation with the ReCasaOS maintainer.

      Kinds: `path` = not shipped (existence asserted), `patch` = local patch (nix/pkgs/*/patches), `pr` = fixed by an
      upstream PR (branch), built from our fork's staging branch until merged (nix/pins/staging.json), `finding` = recorded for review. `TODO` in the last column is an open item, not a decision.

      | Component | Path | Kind | Why | What replaces it | Caller disabled? |
      |---|---|---|---|---|---|
      ${lib.concatStringsSep "\n" rows}
    '';
}
