{ lib, inputs }:
# Component pins, single source: derivations, `checks.*.pin-drift` (T7), `nix eval .#lib.components`.
#
# - pin of record: release/components.lock.json in the pinned root (`inputs.recasaos`)
# - `rev`: what the lock wants (upstream); `inputRev`: what flake.lock holds
# - component with open PRs (nix/pins/preview.json): input = our fork's `recasanix-preview`
#   = `rev` + PR branches merged; `preview.base` must equal `rev`, `inputRev` must equal
#   `preview.head` (T7)
# - other components: `inputRev` must equal `rev`
# - nix/pins/update.sh sets all of it; installer component: not packaged, not exposed
let
  preview = (lib.importJSON ../pins/preview.json).components;
  previewOf = input: preview.${input} or null;

  lock = lib.importJSON "${inputs.recasaos}/release/components.lock.json";
  byLockName = lib.listToAttrs (map (c: lib.nameValuePair c.name c) lock.components);

  fromLock =
    input: lockName:
    {
      # upstream repository, if not the one the lock names
      repo ? lib.removePrefix "https://github.com/" byLockName.${lockName}.source_repository,
    }:
    {
      inherit lockName repo;
      inherit (byLockName.${lockName}) license;
      rev = byLockName.${lockName}.source_revision;
      preview = previewOf input;
      src = inputs.${input};
      inputRev = inputs.${input}.rev;
    };
in
{
  # root: not in its own lock file; `rev` = recorded preview base (upstream root rev)
  recasaos = {
    lockName = null;
    rev = if previewOf "recasaos" != null then (previewOf "recasaos").base else inputs.recasaos.rev;
    preview = previewOf "recasaos";
    inputRev = inputs.recasaos.rev;
    repo = "EdmundFu-233/ReCasaOS";
    license = "Apache-2.0";
    src = inputs.recasaos;
  };
  recasaos-gateway = fromLock "recasaos-gateway" "gateway" { };
  recasaos-user-service = fromLock "recasaos-user-service" "user-service" { };
  recasaos-app-management = fromLock "recasaos-app-management" "app-management" { };
  recasaos-message-bus = fromLock "recasaos-message-bus" "message-bus" { };
  casaos-ui = fromLock "casaos-ui" "administrative-ui" {
    # keep in sync with the flake input URL (AGENTS.md §2 / §6)
    repo = "EdmundFu-233/ReCasaOS-UI";
  };
}
