{ lib, inputs }:
# Component pins, single source: derivations, `checks.*.pin-drift` (T7), `nix eval .#lib.components`.
#
# - pin of record: release/components.env of ReCasaOS/CasaOS-Install (`inputs.recasaos-install`)
# - `rev`: what components.env wants (upstream); `inputRev`: what flake.lock holds
# - component with open PRs (nix/pins/staging.json): input = our fork's `recasanix-staging`
#   = `rev` + PR branches merged; `staging.base` must equal `rev`, `inputRev` must equal
#   `staging.head` (T7)
# - other components: `inputRev` must equal `rev`
# - CasaOS-Common: Go dependency of the root; `rev` = recorded base of the go.mod version
# - nix/pins/update.sh sets all of it
let
  stagingFile = lib.importJSON ../pins/staging.json;
  staging = stagingFile.components;
  stagingOf = input: staging.${input} or null;

  # KEY=VALUE lines; comments and blanks ignored
  parseEnv =
    file:
    lib.listToAttrs (
      map (line: lib.nameValuePair (lib.head line) (lib.concatStringsSep "=" (lib.tail line))) (
        map (lib.splitString "=") (
          lib.filter (line: line != "" && !lib.hasPrefix "#" line) (
            lib.splitString "\n" (builtins.readFile file)
          )
        )
      )
    );
  # the base system (components.env) and the optional modules of the release (modules.env:
  # MODULE_<NAME>_{TAG,COMMIT,COMPONENT,TIER}), one key space
  modulesEnv = "${inputs.recasaos-install}/release/modules.env";
  env =
    parseEnv "${inputs.recasaos-install}/release/components.env"
    // lib.optionalAttrs (builtins.pathExists modulesEnv) (parseEnv modulesEnv);

  # module of the release (`<NAME>` of modules.env) → its flake input; one the release names that
  # has none here is reported by T7
  moduleInputs = {
    VIRT = "recasaos-virt-management";
  };
  releaseModules = map (k: lib.removeSuffix "_TAG" (lib.removePrefix "MODULE_" k)) (
    lib.filter (k: lib.hasPrefix "MODULE_" k && lib.hasSuffix "_TAG" k) (lib.attrNames env)
  );

  # a module: a component, plus what the catalogue entry of the image takes from modules.env and
  # from the module's own module.json at the pinned commit
  fromModule =
    input: name:
    let
      envName = "MODULE_${name}";
      c = fromEnv input envName "ReCasaOS/${env."${envName}_COMPONENT"}";
    in
    c
    // {
      module = {
        name = lib.toLower (lib.replaceStrings [ "_" ] [ "-" ] name);
        component = env."${envName}_COMPONENT";
        tier = env."${envName}_TIER";
        manifest = lib.importJSON "${c.src}/module.json";
      };
    };

  fromEnv = input: envName: repo: {
    inherit envName repo;
    license = "Apache-2.0";
    rev = env."${envName}_COMMIT";
    tag = env."${envName}_TAG";
    staging = stagingOf input;
    src = inputs.${input};
    inputRev = inputs.${input}.rev;
  };
in
{
  # release of the distribution the pins come from (v<…>)
  release = env.CASAOS_RELEASE_TAG;

  # modules.env names (VIRT, …) and the ones with an input here (T7: the first ⊆ the second)
  modules = {
    inRelease = releaseModules;
    known = lib.attrNames moduleInputs;
  };

  recasaos-virt-management = fromModule "recasaos-virt-management" "VIRT";

  recasaos = fromEnv "recasaos" "CASAOS" "ReCasaOS/CasaOS";
  recasaos-gateway = fromEnv "recasaos-gateway" "CASAOS_GATEWAY" "ReCasaOS/CasaOS-Gateway";
  recasaos-user-service =
    fromEnv "recasaos-user-service" "CASAOS_USER_SERVICE"
      "ReCasaOS/CasaOS-UserService";
  recasaos-app-management =
    fromEnv "recasaos-app-management" "CASAOS_APP_MANAGEMENT"
      "ReCasaOS/CasaOS-AppManagement";
  recasaos-message-bus =
    fromEnv "recasaos-message-bus" "CASAOS_MESSAGE_BUS"
      "ReCasaOS/CasaOS-MessageBus";
  casaos-ui = fromEnv "casaos-ui" "CASAOS_UI" "ReCasaOS/CasaOS-UI";

  casaos-common = {
    envName = null;
    repo = "ReCasaOS/CasaOS-Common";
    license = "Apache-2.0";
    rev = (stagingOf "casaos-common").base or inputs.casaos-common.rev;
    tag = stagingFile.common_version or null;
    staging = stagingOf "casaos-common";
    src = inputs.casaos-common;
    inputRev = inputs.casaos-common.rev;
  };
}
