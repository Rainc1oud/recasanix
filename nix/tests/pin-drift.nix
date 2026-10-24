# T7 — pins match the pin of record (ReCasaOS/CasaOS-Install release/components.env).
# - component without open PRs: flake.lock rev == commit in components.env
# - component with open PRs (nix/pins/staging.json): staging base == that commit, flake.lock rev == staging head
# - modules (modules.env, MODULE_<NAME>_COMMIT): as components; every module the release names has an input
# - CasaOS-Common (Go dependency): staging base recorded by update.sh from the root's go.mod; checked:
#   the root (as built) still requires the recorded version, input = staging head
# Fails on a bare `nix flake update`, a single-input update, or a staging branch rebuilt by hand.
{
  lib,
  pkgs,
  components,
}:
let
  rows = lib.mapAttrsToList (name: c: {
    inherit name;
    inherit (c) rev inputRev;
    base = if c.staging == null then "-" else toString (c.staging.base or "-");
    head = if c.staging == null then "-" else toString (c.staging.head or "-");
    isStaging = c.staging != null;
  }) (lib.filterAttrs (_: c: lib.isAttrs c && c ? rev) components);
  # every module the release names (modules.env) has an input here, so it is built and pinned
  missingModules = lib.subtractLists components.modules.known components.modules.inRelease;
  # the Common version the root requires, as built
  rootCommon = lib.findFirst (lib.hasPrefix "github.com/ReCasaOS/CasaOS-Common ") "" (
    map lib.trim (lib.splitString "\n" (builtins.readFile "${components.recasaos.src}/go.mod"))
  );
in
pkgs.runCommand "pin-drift"
  {
    nativeBuildInputs = [ pkgs.jq ];
    rows = builtins.toJSON rows;
    passAsFile = [ "rows" ];
    inherit rootCommon;
    missingModules = lib.concatStringsSep " " missingModules;
    commonTag = toString components.casaos-common.tag;
  }
  ''
    fail=0
    hex40='^[0-9a-f]{40}$'
    while IFS=$'\t' read -r name rev input staging base head; do
      [[ $rev =~ $hex40 ]] || { echo "PIN DRIFT: $name — no 40-hex rev in components.env: '$rev'"; fail=1; }
      if [ "$staging" = true ]; then
        [ "$base" = "$rev" ] || { echo "PIN DRIFT: $name — staging base $base, pin of record wants $rev"; fail=1; }
        [ "$head" = "$input" ] || { echo "PIN DRIFT: $name — flake.lock $input, staging head $head"; fail=1; }
      else
        [ "$rev" = "$input" ] || { echo "PIN DRIFT: $name — pin of record wants $rev, flake.lock has $input"; fail=1; }
      fi
    done < <(jq -r '.[] | [.name, .rev, .inputRev, (.isStaging | tostring), .base, .head] | @tsv' "$rowsPath")
    [ "$rootCommon" = "github.com/ReCasaOS/CasaOS-Common $commonTag" ] || {
      echo "PIN DRIFT: casaos-common — root requires '$rootCommon', staging recorded '$commonTag'"
      fail=1
    }
    [ -z "$missingModules" ] || {
      echo "PIN DRIFT: modules.env names modules without an input here: $missingModules (add one, nix/lib/components.nix moduleInputs)"
      fail=1
    }
    if [ "$fail" -ne 0 ]; then
      echo
      echo "Run nix/pins/update.sh (re-pins every component, rebuilds the staging branches)."
      exit 1
    fi
    echo "all $(jq length "$rowsPath") pins match (staging: base = pin of record, input = staging head)" | tee $out
  ''
