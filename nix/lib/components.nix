{ lib, inputs }:
# Single source of truth for the ReCasaOS component pins: read by the derivations, by
# `checks.*.pin-drift` (T7) and by `nix eval .#lib.components`.
#
# The pin of record is upstream's release/components.lock.json inside the pinned root repository
# (`inputs.recasaos`, locked in flake.lock). `rev` below is what that file says each component must
# be; `inputRev` is what flake.lock actually holds. nix/pins/update.sh makes them equal and T7 fails
# when they are not. The installer component is deliberately not packaged (guardrail in
# DEVELOPMENT.md) and not exposed here.
let
  lock = lib.importJSON "${inputs.recasaos}/release/components.lock.json";
  byLockName = lib.listToAttrs (map (c: lib.nameValuePair c.name c) lock.components);

  fromLock =
    input: lockName:
    {
      # Repository the flake input fetches from, if not the one the lock names.
      repo ? lib.removePrefix "https://github.com/" byLockName.${lockName}.source_repository,
    }:
    {
      inherit lockName repo;
      inherit (byLockName.${lockName}) license;
      rev = byLockName.${lockName}.source_revision;
      src = inputs.${input};
      inputRev = inputs.${input}.rev;
    };
in
{
  # The root is not listed in its own lock file: it pins to the input that carries it.
  recasaos = {
    lockName = null;
    inherit (inputs.recasaos) rev;
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
    # Keep in sync with the flake input URL (AGENTS.md §2 / §6).
    repo = "EdmundFu-233/ReCasaOS-UI";
  };
}
