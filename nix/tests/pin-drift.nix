# T7 — pins match the pin of record.
# - component without open PRs: flake.lock rev == rev in upstream's release/components.lock.json
# - component with open PRs (nix/pins/preview.json): preview base == that rev, flake.lock rev == preview head
# - root: base = pin of record itself (no independent source in Nix); checked: input = head
# Fails on a bare `nix flake update`, a single-input update, or a preview branch rebuilt by hand.
{
  lib,
  pkgs,
  components,
}:
let
  rows = lib.mapAttrsToList (name: c: {
    inherit name;
    inherit (c) rev inputRev;
    base = if c.preview == null then "-" else toString (c.preview.base or "-");
    head = if c.preview == null then "-" else toString (c.preview.head or "-");
    isPreview = c.preview != null;
  }) components;
in
pkgs.runCommand "pin-drift"
  {
    nativeBuildInputs = [ pkgs.jq ];
    rows = builtins.toJSON rows;
    passAsFile = [ "rows" ];
  }
  ''
    fail=0
    hex40='^[0-9a-f]{40}$'
    while IFS=$'\t' read -r name rev input preview base head; do
      [[ $rev =~ $hex40 ]] || { echo "PIN DRIFT: $name — no 40-hex rev in components.lock.json: '$rev'"; fail=1; }
      if [ "$preview" = true ]; then
        [ "$base" = "$rev" ] || { echo "PIN DRIFT: $name — preview base $base, lock wants $rev"; fail=1; }
        [ "$head" = "$input" ] || { echo "PIN DRIFT: $name — flake.lock $input, preview head $head"; fail=1; }
      else
        [ "$rev" = "$input" ] || { echo "PIN DRIFT: $name — lock wants $rev, flake.lock has $input"; fail=1; }
      fi
    done < <(jq -r '.[] | [.name, .rev, .inputRev, (.isPreview | tostring), .base, .head] | @tsv' "$rowsPath")
    if [ "$fail" -ne 0 ]; then
      echo
      echo "Run nix/pins/update.sh (re-pins every component, rebuilds the preview branches)."
      exit 1
    fi
    echo "all $(jq length "$rowsPath") pins match (previews: base = lock rev, input = preview head)" | tee $out
  ''
