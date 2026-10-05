# T9 — mechanical enforcement of the cross-cutting guardrail (DEVELOPMENT.md, "Cross-cutting
# guardrail — strip upstream's host-management machinery"). Two halves:
#   1. closure scan: nothing the register excludes may reappear in the sysroot / system units, and no
#      package-manager or unit-enable calls may survive;
#   2. register completeness: docs/upstream-exclusions.md is exactly the register rendered from
#      nix/lib/exclusions.nix, so every excluded path has a row that says whether its caller was cut.
{
  lib,
  pkgs,
  exclusions,
  nixos,
}:
let
  # Every path the derivations remove from a sysroot, as installed-relative paths.
  excluded = lib.unique (
    lib.concatMap (
      es:
      map (e: lib.removePrefix "build/sysroot/" e.path) (
        lib.filter (e: e.kind == "path" && lib.hasPrefix "build/sysroot/" e.path) es
      )
    ) (lib.attrValues exclusions.components)
  );

  # Units of the appliance that belong to ReCasaOS (empty until the module of task 3.1 exists).
  systemUnits = lib.filterAttrs (
    n: u: (lib.hasPrefix "casaos" n || lib.hasPrefix "recasaos" n) && u.text != null
  ) nixos.config.systemd.units;
  unitsDir = pkgs.linkFarm "recasaos-system-units" (
    lib.mapAttrsToList (name: u: {
      inherit name;
      path = pkgs.writeText name u.text;
    }) systemUnits
  );

  msg = ''
    Host-management machinery must not ship on ReCasaNix. This is a deliberate policy, not a packaging
    bug: see "Cross-cutting guardrail" in DEVELOPMENT.md and the register docs/upstream-exclusions.md.
    Exclude the path in nix/lib/exclusions.nix (which also updates the register), patch its caller out,
    and refresh the register: nix build .#exclusions-register && install -m644 result docs/upstream-exclusions.md
  '';
in
pkgs.runCommand "no-host-management"
  {
    inherit msg;
    sysroot = pkgs.casaos-sysroot;
    inherit unitsDir;
    register = ../../docs/upstream-exclusions.md;
    rendered = pkgs.writeText "upstream-exclusions.md" exclusions.register;
    excludedPaths = excluded;
  }
  ''
    fail() { echo "GUARDRAIL VIOLATION: $1" >&2; echo "$msg" >&2; exit 1; }
    root="$sysroot/share/casaos-sysroot"

    # 1a. excluded paths must not reappear after an upstream bump
    for p in $excludedPaths; do
      [ ! -e "$root/$p" ] || fail "excluded path is present in the sysroot: $p"
    done

    # 1b. no distro-lifecycle, package-manager or runtime unit-enable machinery anywhere
    if hits="$(grep -rlE '\b(apt-get|apt|dpkg|pacman|yum|dnf)\b' "$root" "$unitsDir")" && [ -n "$hits" ]; then
      fail "package-manager call in: $hits"
    fi
    if hits="$(grep -rlE 'systemctl +(enable|disable|daemon-reload)' "$root" "$unitsDir")" && [ -n "$hits" ]; then
      fail "runtime unit enable/disable in: $hits"
    fi
    if hits="$(grep -rlE 'update\.sh|delete-old-service' "$root" "$unitsDir")" && [ -n "$hits" ]; then
      fail "reference to an excluded update script in: $hits"
    fi

    # 1c. /etc/casaos/start.d is executed by casaos at startup: only the UI's event-registration
    #     script may live there (anything else is arbitrary code execution from a config directory).
    if [ -d "$root/etc/casaos/start.d" ]; then
      unexpected="$(ls "$root/etc/casaos/start.d" | grep -vx register-ui-events.sh || true)"
      [ -z "$unexpected" ] || fail "unexpected start.d hook(s): $unexpected"
    fi

    # 2. the register is exactly what the exclusions list renders to
    if ! diff -u "$register" "$rendered"; then
      fail "docs/upstream-exclusions.md is out of date with nix/lib/exclusions.nix"
    fi

    touch $out
  ''
