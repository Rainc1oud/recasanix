# casaos-ui — the CasaOS Vue app, built offline from its pnpm lockfile (task 1.6).
{
  lib,
  stdenv,
  nodejs_22,
  pnpm_10,
  fetchPnpmDeps,
  pnpmConfigHook,
  components,
  src,
}:
let
  # Upstream declares pnpm@9.0.6 in package.json, but pnpm 9 is EOL and removed from nixpkgs. The
  # lockfile is format 9.0, which pnpm 10 reads; pin a major to keep the store format stable.
  pnpm = pnpm_10;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "casaos-ui";
  # package.json says v0.4.5 but is not bumped per release; identify the build by its pinned revision.
  version = "0-unstable-${builtins.substring 0 7 components.casaos-ui.rev}";
  inherit src;

  # Host-management guardrail (docs/upstream-exclusions.md): remove the in-place update UI, and
  # stop webpack from stringifying the whole build environment into the bundle.
  patches = [
    ./patches/0001-disable-self-update.patch
    ./patches/0002-vue-config-reproducible-env.patch
    ./patches/0003-send-bearer-authorization.patch
    ./patches/0004-storage-panel-finally-typo.patch
    ./patches/0005-feat-events-present-the-service-credential-when-regi.patch
    ./patches/0006-chore-ui-drop-the-IceWhale-community-links-and-the-b.patch
  ];

  nativeBuildInputs = [
    nodejs_22
    pnpmConfigHook
    pnpm
  ];

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 4;
    hash = "sha256-MEIk6ZE7WNKWBt0l26K8WjzjIstG0LBVVSpYJlJ9pFc=";
  };

  # Upstream's `pnpm build`, with the destination directed at $out. `.env.production` (NODE_ENV=prod)
  # is read by vue-cli itself; nothing here overrides API base paths.
  buildPhase = ''
    runHook preBuild
    # pnpm does not run dependency lifecycle scripts. @vue-office/* ship their entry point through a
    # postinstall that copies lib/v2/index.js (Vue 2) to lib/index.js; run exactly those, and only those.
    for pkg in docx excel pdf; do
      (cd "node_modules/@vue-office/$pkg" && node lib/script/postinstall.js)
    done

    # Also writes build/sysroot/var/lib/casaos/ui-message-bus.json and
    # build/sysroot/etc/casaos/start.d/register-ui-events.sh (run by casaos at start to register the
    # UI's event types with the message bus; see the start.d note in docs/upstream-exclusions.md).
    node message_bus.build.js
    pnpm exec vue-cli-service build --dest build/sysroot/var/lib/casaos/www/ --mode production
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share"
    cp -r build/sysroot "$out/share/casaos-sysroot"
    # `#!/usr/bin/bash` does not exist on NixOS; resolve bash through the session (AGENTS.md §5).
    substituteInPlace "$out/share/casaos-sysroot/etc/casaos/start.d/register-ui-events.sh" \
      --replace-fail '#!/usr/bin/bash' '#!/usr/bin/env bash'
    runHook postInstall
  '';

  # `pnpm test` (vitest) runs as a separate check (T1), not in the build.
  doCheck = false;

  meta = {
    description = "CasaOS web UI (Vue), the dashboard served by the gateway";
    homepage = "https://github.com/${components.casaos-ui.repo}";
    # No LICENSE file upstream (AGENTS.md §6): all rights reserved. Fine for internal prototypes;
    # must be resolved with upstream before commercial distribution. The source is switchable to
    # EdmundFu-233/ReCasaOS-UI in nix/lib/components.nix.
    license = lib.licenses.unfree;
    platforms = lib.platforms.linux;
  };
})
