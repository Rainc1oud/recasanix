# T7 — the flake inputs must be exactly the revisions upstream's release/components.lock.json (in the
# pinned root repository) names. Fails when someone updates one component without the others, e.g. a
# bare `nix flake update` or `nix flake update recasaos-gateway`: that floats it to its branch head.
{
  lib,
  pkgs,
  components,
}:
let
  rows = lib.mapAttrsToList (name: c: {
    inherit name;
    inherit (c) rev inputRev;
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
    while IFS=$'\t' read -r name rev input; do
      case "$rev" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) echo "PIN DRIFT: $name has no 40-hex revision in components.lock.json: '$rev'"; fail=1 ;;
      esac
      if [ "$rev" != "$input" ]; then
        echo "PIN DRIFT: $name — components.lock.json wants $rev, flake.lock has $input"
        fail=1
      fi
    done < <(jq -r '.[] | [.name, .rev, .inputRev] | @tsv' "$rowsPath")
    if [ "$fail" -ne 0 ]; then
      echo
      echo "Run nix/pins/update.sh to re-pin every component to the lock file of the pinned root repository."
      echo "(Never update a single component input on its own; see the comment in flake.nix.)"
      exit 1
    fi
    echo "all $(jq length "$rowsPath") pins match components.lock.json" | tee $out
  ''
