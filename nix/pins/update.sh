#!/usr/bin/env bash
# Re-pin ReCasaOS, with our open upstream PRs merged in.   Usage: nix/pins/update.sh [<install-rev>]
#
# - pin of record: ReCasaOS/CasaOS-Install release/components.env + release/modules.env at <install-rev>
#   (tag or commit; default: latest release) → `<NAME>_COMMIT` per component, `MODULE_<NAME>_COMMIT` per module
# - CasaOS-Common (Go dependency, not a component): the version the root's go.mod requires at its pin
# - component with open PRs (nix/pins/staging.json): base + PR branches merged in order
#   → pushed as `recasanix-staging` to our fork → flake input = that head
# - other components: flake input = upstream at base
# - records base/head in staging.json; T7 (pin-drift) checks them
# - PR already in base (merged upstream) → reported; drop it from staging.json
# Needs: push access to the forks (SSH agent).
set -euo pipefail
cd "$(dirname "$0")/../.."
repo_root=$PWD
json=nix/pins/staging.json
branch=$(jq -r .branch "$json")
work=$(mktemp -d)
trap '[ -e "$work/.keep" ] || rm -rf "$work"' EXIT

pins() { jq -r '.nodes | to_entries[] | select(.key | test("^(recasaos|casaos-)")) | "\(.key) \(.value.locked.owner)/\(.value.locked.repo) \(.value.locked.rev)"' flake.lock; }
before="$(pins)"

# pin of record: CasaOS-Install at a release
install_repo=ReCasaOS/CasaOS-Install
git clone -q --filter=blob:none --no-checkout "https://github.com/$install_repo" "$work/install"
install_rev=${1:-$(gh release view -R "$install_repo" --json tagName --jq .tagName)}
install_rev=$(git -C "$work/install" rev-parse "$install_rev^{commit}")
# components.env (the base system) and modules.env (the optional modules, MODULE_<NAME>_*), one key space
envfile=$(git -C "$work/install" show "$install_rev:release/components.env")
envfile+=$'\n'$(git -C "$work/install" show "$install_rev:release/modules.env" 2>/dev/null || true)
env_commit() { sed -n "s/^$1_COMMIT=//p" <<<"$envfile"; }

declare -A env_name=(
  [recasaos]=CASAOS [recasaos-gateway]=CASAOS_GATEWAY [recasaos-user-service]=CASAOS_USER_SERVICE
  [recasaos-app-management]=CASAOS_APP_MANAGEMENT [recasaos-message-bus]=CASAOS_MESSAGE_BUS [casaos-ui]=CASAOS_UI
  [recasaos-virt-management]=MODULE_VIRT
)
declare -A upstream_repo=(
  [recasaos]=ReCasaOS/CasaOS [recasaos-gateway]=ReCasaOS/CasaOS-Gateway [recasaos-user-service]=ReCasaOS/CasaOS-UserService
  [recasaos-app-management]=ReCasaOS/CasaOS-AppManagement [recasaos-message-bus]=ReCasaOS/CasaOS-MessageBus
  [casaos-ui]=ReCasaOS/CasaOS-UI [casaos-common]=ReCasaOS/CasaOS-Common
  [recasaos-virt-management]=ReCasaOS/CasaOS-VirtManagement
)
# every module the release names needs an input (nix/lib/components.nix moduleInputs, flake.nix)
for m in $(sed -n 's/^MODULE_\([A-Z0-9_]*\)_TAG=.*/\1/p' <<<"$envfile"); do
  printf '%s\n' "${env_name[@]}" | grep -qx "MODULE_$m" || {
    echo "modules.env names MODULE_$m: add its input (flake.nix, components.nix moduleInputs, update.sh env_name)" >&2
    exit 1
  }
done

# CasaOS-Common: the version the pinned root requires
root_commit=$(env_commit CASAOS)
git clone -q --filter=blob:none --no-checkout "https://github.com/ReCasaOS/CasaOS" "$work/root"
common_version=$(git -C "$work/root" show "$root_commit:go.mod" | awk '$1 == "github.com/ReCasaOS/CasaOS-Common" { print $2 }')
common_commit=$(git ls-remote "https://github.com/ReCasaOS/CasaOS-Common" "refs/tags/$common_version^{}" "refs/tags/$common_version" | awk 'NR == 1 { print $1 }')
[ -n "$common_commit" ] || {
  echo "CasaOS-Common $common_version: no such tag" >&2
  exit 1
}

base_of() { if [ "$1" = casaos-common ]; then echo "$common_commit"; else env_commit "${env_name[$1]}"; fi; }

# staging: base + PRs → fork's staging branch
staging() { # <input> <base>  → prints head
  local input=$1 base=$2 fork dir
  fork=$(jq -r --arg i "$input" '.components[$i].fork' "$json")
  dir="$work/$input"
  git clone -q "https://github.com/$fork" "$dir"
  git -C "$dir" remote add upstream "https://github.com/${upstream_repo[$input]}"
  git -C "$dir" fetch -q upstream
  git -C "$dir" checkout -q -B "$branch" "$base"
  while read -r pr; do
    if git -C "$dir" merge-base --is-ancestor "origin/$pr" "$base"; then
      echo "  $input: $pr already in base (merged upstream) → drop it from $json" >&2
      continue
    fi
    # machine-made merge commits: unsigned
    git -C "$dir" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" -c commit.gpgsign=false \
      merge -q --no-ff --no-edit -m "staging: merge $pr" "origin/$pr" >&2 || {
      echo "  $input: merge of $pr failed (conflict?) — clone kept: $dir" >&2
      touch "$work/.keep"
      exit 1
    }
  done < <(jq -r --arg i "$input" '.components[$i].prs[]' "$json")
  git -C "$dir" push -q --force "git@github.com:$fork.git" "$branch" >&2
  git -C "$dir" rev-parse HEAD
}

jq --arg r "$install_rev" --arg v "$common_version" '.install = $r | .common_version = $v' "$json" >"$json.new" && mv "$json.new" "$json"
overrides=(--override-input recasaos-install "github:$install_repo/$install_rev")
for input in "${!upstream_repo[@]}"; do
  base=$(base_of "$input")
  [[ $base =~ ^[0-9a-f]{40}$ ]] || {
    echo "$input: no commit in the pin of record ('$base')" >&2
    exit 1
  }
  if jq -e --arg i "$input" '.components | has($i)' "$json" >/dev/null; then
    echo "staging $input: base ${base:0:9}" >&2
    head=$(staging "$input" "$base")
    jq --arg i "$input" --arg b "$base" --arg h "$head" '.components[$i].base = $b | .components[$i].head = $h' \
      "$json" >"$json.new" && mv "$json.new" "$json"
    overrides+=(--override-input "$input" "github:$(jq -r --arg i "$input" '.components[$i].fork' "$json")/$head")
  else
    overrides+=(--override-input "$input" "github:${upstream_repo[$input]}/$base")
  fi
done
cd "$repo_root"
nix flake lock "${overrides[@]}"

after="$(pins)"
diff <(echo "$before") <(echo "$after") && echo "pins unchanged" || true
