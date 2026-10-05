#!/usr/bin/env bash
# Bump the ReCasaOS pins.   Usage: nix/pins/update.sh [<root-revision>]
#
# The root repository (`recasaos`) is the pin of record: this moves it (to <root-revision>, or to the
# head of its branch), reads the release/components.lock.json of the revision it landed on, and pins
# every other component input to the revision named there with `nix flake lock --override-input`.
# flake.lock keeps the resulting revisions and hashes; flake.nix keeps unpinned URLs. Prints a
# before/after listing to review — and the guardrail asks for a fresh host-management audit of
# docs/upstream-exclusions.md on every bump. `checks.*.pin-drift` (T7) verifies the outcome.
set -euo pipefail
cd "$(dirname "$0")/../.."

pins() { nix eval --json .#lib.components --apply 'builtins.mapAttrs (_: v: v.inputRev)' | jq -r 'to_entries[] | "\(.key) \(.value)"'; }

before="$(pins)"

if [ $# -ge 1 ]; then
  nix flake lock --override-input recasaos "github:EdmundFu-233/ReCasaOS/$1"
else
  nix flake update recasaos
fi

# Desired revisions come from the lock file of the root revision we just locked.
overrides=()
while read -r input repo rev; do
  overrides+=(--override-input "$input" "github:$repo/$rev")
done < <(nix eval --json .#lib.components --apply \
  'c: builtins.mapAttrs (_: v: { inherit (v) repo rev; }) (removeAttrs c [ "recasaos" ])' \
  | jq -r 'to_entries[] | "\(.key) \(.value.repo) \(.value.rev)"')
nix flake lock "${overrides[@]}"

after="$(pins)"
diff <(echo "$before") <(echo "$after") && echo "pins unchanged" || true
