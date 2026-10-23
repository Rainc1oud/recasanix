# casaos-ui — the CasaOS dashboard (ReCasaOS org, Vue 3), built offline from its pnpm lockfile (task 1.6).
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

  # No local patch: update/package/module rows follow the core (`[server] ImageManaged`, upstream PR
  # in our staging); the build environment is no longer stringified into the bundle upstream.

  nativeBuildInputs = [
    nodejs_22
    pnpmConfigHook
    pnpm
  ];

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 4;
    hash = "sha256-Wl4dRXFs3G9y4BfuTyHn57zfs0An+W8mbAKSex7rHuc=";
  };

  # Upstream's `pnpm build`, with the destination directed at $out. `.env.production` (NODE_ENV=prod)
  # is read by vue-cli itself; nothing here overrides API base paths.
  buildPhase = ''
    runHook preBuild
    # pnpm does not run dependency lifecycle scripts. @vue-office/* ship their entry point through a
    # postinstall that copies lib/v<major>/index.js (the installed Vue's) to lib/index.js; run exactly
    # those, and only those.
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
    runHook postInstall
  '';

  # `pnpm test` (vitest) runs as a separate check (T1), not in the build.
  doCheck = false;

  meta = {
    description = "CasaOS web UI (Vue 3, dark theme), the dashboard served by the gateway";
    homepage = "https://github.com/${components.casaos-ui.repo}";
    # AGENTS.md §6: IceWhale code + org maintainer's changes Apache-2.0 (LICENSE, NOTICE); alvins82's
    # pre-org commits not covered → unfree until he answers, then asl20 + drop allowUnfreePredicate.
    license = lib.licenses.unfree;
    platforms = lib.platforms.linux;
  };
})
