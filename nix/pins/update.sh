#!/usr/bin/env bash
# Re-pin ReCasaOS, with our open upstream PRs merged in.   Usage: nix/pins/update.sh [<root-rev>]
#
# - root = pin of record: <root-rev> or upstream main
# - each component's base = rev in the root's release/components.lock.json
# - component with open PRs (nix/pins/preview.json): base + PR branches merged in order
#   → pushed as `recasanix-preview` to our fork → flake input = that head
# - other components: flake input = base
# - records base/head in preview.json; T7 (pin-drift) checks them
# - PR already in base (merged upstream) → reported; drop it from preview.json
# Needs: push access to the forks (SSH agent).
set -euo pipefail
cd "$(dirname "$0")/../.."
repo_root=$PWD
json=nix/pins/preview.json
branch=$(jq -r .branch "$json")
work=$(mktemp -d)
trap '[ -e "$work/.keep" ] || rm -rf "$work"' EXIT

pins() { jq -r '.nodes | to_entries[] | select(.key | test("^(recasaos|casaos-ui)")) | "\(.key) \(.value.locked.owner)/\(.value.locked.repo) \(.value.locked.rev)"' flake.lock; }
before="$(pins)"

# root rev → upstream lock file
root_upstream=$(jq -r '.components.recasaos.upstream' "$json")
git clone -q --filter=blob:none --no-checkout "https://github.com/$root_upstream" "$work/root"
root_rev=${1:-$(git -C "$work/root" rev-parse origin/HEAD)}
root_rev=$(git -C "$work/root" rev-parse "$root_rev^{commit}")
lock=$(git -C "$work/root" show "$root_rev:release/components.lock.json")
lock_rev() { jq -r --arg n "$1" '.components[] | select(.name == $n) | .source_revision' <<<"$lock"; }
declare -A lock_name=(
  [recasaos-gateway]=gateway [recasaos-user-service]=user-service [recasaos-app-management]=app-management
  [recasaos-message-bus]=message-bus [casaos-ui]=administrative-ui
)

# preview: base + PRs → fork's preview branch
preview() { # <input> <base>  → prints head
  local input=$1 base=$2 upstream fork dir
  upstream=$(jq -r --arg i "$input" '.components[$i].upstream' "$json")
  fork=$(jq -r --arg i "$input" '.components[$i].fork' "$json")
  dir="$work/$input"
  git clone -q "https://github.com/$fork" "$dir"
  git -C "$dir" remote add upstream "https://github.com/$upstream"
  git -C "$dir" fetch -q upstream
  git -C "$dir" checkout -q -B "$branch" "$base"
  while read -r pr; do
    if git -C "$dir" merge-base --is-ancestor "origin/$pr" "$base"; then
      echo "  $input: $pr already in base (merged upstream) → drop it from $json" >&2
      continue
    fi
    # machine-made merge commits: unsigned
    git -C "$dir" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" -c commit.gpgsign=false \
      merge -q --no-ff --no-edit -m "preview: merge $pr" "origin/$pr" >&2 || {
      echo "  $input: merge of $pr failed (conflict?) — clone kept: $dir" >&2
      touch "$work/.keep"
      exit 1
    }
  done < <(jq -r --arg i "$input" '.components[$i].prs[]' "$json")
  git -C "$dir" push -q --force "git@github.com:$fork.git" "$branch" >&2
  git -C "$dir" rev-parse HEAD
}

overrides=()
for input in $(jq -r '.components | keys[]' "$json") recasaos-gateway; do
  if [ "$input" = recasaos ]; then base=$root_rev; else base=$(lock_rev "${lock_name[$input]}"); fi
  if jq -e --arg i "$input" '.components | has($i)' "$json" >/dev/null; then
    echo "preview $input: base ${base:0:9}" >&2
    head=$(preview "$input" "$base")
    jq --arg i "$input" --arg b "$base" --arg h "$head" '.components[$i].base = $b | .components[$i].head = $h' \
      "$json" >"$json.new" && mv "$json.new" "$json"
    overrides+=(--override-input "$input" "github:$(jq -r --arg i "$input" '.components[$i].fork' "$json")/$head")
  else
    overrides+=(--override-input "$input" "github:EdmundFu-233/ReCasaOS-Gateway/$base")
  fi
done
cd "$repo_root"
nix flake lock "${overrides[@]}"

after="$(pins)"
diff <(echo "$before") <(echo "$after") && echo "pins unchanged" || true
