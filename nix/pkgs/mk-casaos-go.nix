# Shared recipe for the Go services (task 1.1, casaos-gateway, is the reference implementation).
#
# Arguments beyond the ones named here (version, src, vendorHash, subPackages, patches, ...) go
# straight to buildGoModule.
{
  lib,
  buildGoModule,
  exclusions,
}:
{
  pname,
  # Go names a binary after its package directory; map that name to the upstream release name.
  renameBinaries,
  description,
  repo,
  mainProgram,
  # Extra shell run after the sysroot is installed, from the source root.
  extraPostInstall ? "",
  ...
}@args:
buildGoModule (
  {
    # No UPX (non-reproducible, breaks debugging). The version is a constant in upstream's source
    # (common/version.go or common/constants.go), so there is nothing to inject via ldflags.
    ldflags = [
      "-s"
      "-w"
    ];

    # Upstream Go tests run as a separate check (T1, `checks.*.unit-*`) so a flaky upstream test
    # cannot block an image build.
    doCheck = false;

    postInstall = ''
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (from: to: ''mv "$out/bin/${from}" "$out/bin/${to}"'') renameBinaries
      )}

      # Harvest upstream's build/sysroot tree (units, shell helpers, sample config, assets) minus
      # everything the host-management guardrail excludes. Downstream modules read it from here.
      ${exclusions.installSysroot pname}
      ${extraPostInstall}
    '';

    meta = {
      inherit description mainProgram;
      homepage = "https://github.com/${repo}";
      license = lib.licenses.asl20;
      platforms = lib.platforms.linux;
    };
  }
  // removeAttrs args [
    "description"
    "repo"
    "mainProgram"
    "renameBinaries"
    "extraPostInstall"
  ]
)
