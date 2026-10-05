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
        path = "route/*.go: Authorization header parsing (patches/0001-accept-bearer-authorization.patch)";
        kind = "patch";
        why = "Not host management — an upstream integration break: this service takes the whole Authorization header value as the token, so `Bearer <token>` (the form the root service requires and the fork calls preferred) is a 401 here while the bare form is a 401 at the root service. No single header satisfied both; the UI showed a first login followed by an immediate logout. Invisible to curl from inside the machine because this service skips authentication for loopback clients.";
        replacedBy = "The service strips an optional `Bearer ` prefix (bare tokens still work).";
        caller = "n/a — found by the browser check ui-login (T-UI). Note: the loopback auth skip relies on the gateway overwriting X-Forwarded-For; worth a review upstream.";
      }
    ];
    casaos-user-service = perService { name = "user-service"; } ++ [
      {
        path = "main.go: go route.EventListen()";
        kind = "patch";
        why = "Subscribes to the message bus source `local-storage`, which belonged to the separate CasaOS-LocalStorage service that ReCasaOS does not ship (no storage manager is part of the pinned ReCasaOS set: the UI's disk panels have no backend). Nothing registers it, the bus answers 400 and the loop retries every second (1000 times) — pure journal noise.";
        replacedBy = "Nothing; the events it would persist do not exist.";
        caller = "n/a — no UI or API depends on it (patches/0001-drop-local-storage-listener.patch)";
      }
    ];
    casaos-app-management =
      perService {
        name = "app-management";
        buildroot = true;
      }
      ++ [
        {
          path = "route/*.go: Authorization header parsing (patches/0001-accept-bearer-authorization.patch)";
          kind = "patch";
          why = "Not host management — same upstream integration break as in message-bus: the whole Authorization header value is taken as the token, so `Bearer <token>` (required by the root service) was a 401 here. Invisible from inside the machine because this service skips authentication for loopback clients.";
          replacedBy = "The service strips an optional `Bearer ` prefix (bare tokens still work).";
          caller = "n/a — found by the browser check ui-login (T-UI).";
        }
        {
          path = "route/v1/docker.go: PutDockerDaemonConfiguration";
          kind = "finding";
          why = "Rewrites /etc/docker/daemon.json, then `systemctl daemon-reload`, stop and start of docker.service from an API call.";
          replacedBy = "virtualisation.docker settings and data-root on the data pool (task 3.3).";
          caller = "yes — route registration is already commented out upstream (route/v1.go); UI still carries docker_root_dir plumbing in AppPanel.vue, harmless while the route is absent. Re-check on every bump.";
        }
      ];
    casaos = perService { name = "casaos"; } ++ [
      {
        path = "${common}/shell/update.sh";
        kind = "path";
        why = "Upstream self-update entry point (a stub that hard-exits in this fork).";
        replacedBy = "Image/OTA pipeline (RAUC, later phase).";
        caller = "yes — nothing in the Go code executes it; the API routes are removed by the patch below";
      }
      {
        path = "${common}/shell/delete-old-service.sh";
        kind = "path";
        why = "Deletes old unit files and binaries under /usr and /etc and restarts the service with systemctl.";
        replacedBy = "Nothing; units are declarative.";
        caller = "n/a — not referenced by any Go code";
      }
      {
        path = "route/v1.go, route/v1/system.go: GET /v1/sys/version (network check), POST /v1/sys/update";
        kind = "patch";
        why = "Self-update over the network: the version check queried GitHub releases and SystemUpdate called UpdateSystemVersion (a stub in this fork that always errors).";
        replacedBy = "Vendor-managed image updates.";
        caller = "yes — POST /update removed; GET /version kept but answers locally (need_update=false, running version) because the UI calls it right after login and treats any failure as a failed login (patches/0001-disable-host-management-routes.patch). UI: Update block removed from the TopBar menu and checkVersion() made a no-op (casaos-ui patches/0001-disable-self-update.patch)";
      }
      {
        path = "route/v1.go: POST /v1/sys/stop";
        kind = "patch";
        why = "PostKillCasaOS calls os.Exit(0) — a UI-triggered self-kill of the service (systemd restarts it).";
        replacedBy = "Nothing; restarting a service is an operator action, not a UI one.";
        caller = "yes — route removed (same patch); the UI has no caller for it";
      }
      {
        path = "${common}/shell/helper.sh: DockerImgMove, PackageDocker, SetLink, TarFolder, USB_Start_Auto, USB_Stop_Auto, EditSmabaUserPassword, AddSmabaUser, ReloadSamba";
        kind = "patch";
        why = "Functions that rewrite /etc/docker/daemon.json, stop docker, enable/disable devmon units, create host users with useradd/smbpasswd, call /etc/init.d/smbd, or delete symlinks under /DATA.";
        replacedBy = "Nothing is needed: no caller. Docker runtime setup is cold-layer Nix (task 3.3); users and shares are hot state owned by the CasaOS services (own database → generated config → reload), not by host scripts.";
        caller = "n/a — no Go code, no other component and no UI calls these functions (only GetDeviceTree, CatNetCardState, GetNetCard, GetTimeZone, GetSysInfo and RestartSMBD are called). Patch: patches/0002-helper-strip-host-management.patch";
      }
      {
        path = "${common}/shell/{helper,usb-mount}.sh: absolute /bin/* paths";
        kind = "patch";
        why = "/bin/rm, /bin/rmdir, /bin/kill: NixOS has no /bin beyond sh. The prefix is deleted so the unit's PATH resolves the command (AGENTS.md §5).";
        replacedBy = "systemd.services.casaos.path (task 3.1).";
        caller = "n/a";
      }
      {
        path = "service/shares.go, service/system.go: absolute /bin/bash (patches/0003-bash-from-path.patch)";
        kind = "patch";
        why = "Absolute /bin/bash does not exist on NixOS. shares.go spawned it directly; system.go went through CasaOS-Common's command.OnlyExec, which hardcodes it too, so every helper.sh call would fail. Both now run bare `bash`, resolved through the unit's PATH.";
        replacedBy = "systemd.services.casaos.path contains bash (task 3.1).";
        caller = "n/a";
      }
      {
        path = "helper.sh: RestartSMBD (systemctl restart smbd)";
        kind = "finding";
        why = "Restarts smbd (Debian unit name; NixOS calls it samba-smbd.service) after the shares service — hot state — has generated /etc/samba/smb.casa.conf and validated it with testparm. That generate-validate-reload pattern is the intended architecture, so this stays.";
        replacedBy = "TODO(3.1/3.2): decide SMB scope; either alias the unit or patch the name, and give the baseline smb.conf (store) an `include` of the runtime smb.casa.conf on the state partition.";
        caller = "TODO — kept deliberately; the SMB path is unexercised by tests (Phase 6)";
      }
      {
        path = "service/system.go: SystemReboot / SystemShutdown (`init 6` / `init 0`)";
        kind = "finding";
        why = "UI power buttons. Reboot and shutdown are legitimate appliance actions, but the mechanism (SysV `init`) is not portable to NixOS.";
        replacedBy = "TODO(3.1): patch to `systemctl reboot` / `systemctl poweroff` or provide `init` on the unit's path.";
        caller = "TODO — kept deliberately (PutSystemState); review in task 3.1";
      }
      {
        path = "main.go: command.ExecuteScripts(/etc/casaos/start.d)";
        kind = "finding";
        why = "Executes every script in /etc/casaos/start.d at startup (CasaOS-Common command.ExecuteScripts, via /bin/sh) — arbitrary code execution from a config directory. The one legitimate occupant is the UI's register-ui-events.sh (registers UI event types with the message bus; shebang normalised to `/usr/bin/env bash`, needs curl on the unit's PATH — task 3.1).";
        replacedBy = "T9 asserts the shipped start.d holds only register-ui-events.sh; recasanix-state-init rebuilds it on every boot, so a persistent tamper cannot survive (T4 asserts this).";
        caller = "TODO — kept deliberately (needed for UI events); vendor-owned and rebuilt each boot (task 3.2)";
      }
      {
        path = "${common}/shell/usb-mount@.service, usr/lib/systemd/system/rclone.service";
        kind = "finding";
        why = "Upstream units the NixOS module (task 3.1) does not define: the udev-triggered removable-media template hardcodes /casaOS/server/shell and /DATA/USB_Storage_*, and rclone backs cloud-drive mounting. Both stay in the sysroot as inert files (no unit is generated from them).";
        replacedBy = "rclone: dropped for good (cloud-drive mounting is not a product feature; casaos.service is not ordered After=rclone.service). Removable media: to be reinstated (owner decision) as a NixOS-native template unit and udev rule mounting below the file roots — deferred until the major topics (state boundary, apps, image) are tested.";
        caller = "TODO — until removable media is reinstated the UI's USB affordance is non-functional; the cloud-drive one stays that way for good (cut it when convenient)";
      }
      {
        path = "cmd/migration-tool";
        kind = "finding";
        why = "Each repo builds a migration-tool binary that drives systemctl on a Debian host.";
        replacedBy = "Not built: derivations use explicit subPackages.";
        caller = "n/a";
      }
    ];
    casaos-ui = [
      {
        path = "src/service/service.js, src/components/filebrowser/FilePanel.vue, …: Authorization header";
        kind = "patch";
        why = "Not host management — an upstream integration break found while onboarding: the pinned UI sends the bare access token in `Authorization`, but the root service only accepts `Bearer <token>` (user-service tolerates both, upstream's declared 'compatibility hold'). Every root-service call from the browser was a 401 and login looked dead.";
        replacedBy = "The UI sends `Bearer <token>` everywhere (the form upstream's own notes say the UI should move to). Not fixed: the wallpaper upload still puts the token in a `?token=` query, which the fork rejects — report upstream.";
        caller = "n/a (patches/0003-send-bearer-authorization.patch)";
      }
      {
        path = "src/components/TopBar.vue: Update block, checkVersion";
        kind = "patch";
        why = "Polls /v1/sys/version and offers the in-place update flow (UpdateModal calls POST /v1/sys/update).";
        replacedBy = "Vendor-managed image updates.";
        caller = "yes — the Update block is removed from the TopBar settings menu and checkVersion() no longer queries the API (patches/0001-disable-self-update.patch)";
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

      Kinds: `path` = not shipped (existence asserted), `patch` = patched out of source/scripts,
      `finding` = recorded for review. `TODO` in the last column is an open item, not a decision.

      | Component | Path | Kind | Why | What replaces it | Caller disabled? |
      |---|---|---|---|---|---|
      ${lib.concatStringsSep "\n" rows}
    '';
}
