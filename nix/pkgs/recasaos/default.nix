# casaos — the ReCasaOS root service (task 1.5) plus the isolated public-file portal.
{
  mkCasaosGo,
  components,
  src,
}:
mkCasaosGo {
  pname = "casaos";
  # upstream: common/constants.go (VERSION)
  version = "0.4.17-recasaos.1";
  inherit src;
  vendorHash = "sha256-6qHqDTIWl6HU8HOtf16nOdz2Et8iPcIVp6vxYZAmo+I=";

  # Deviation from upstream (CGO_ENABLED=1, CGO_LDFLAGS=-static, UPX): nothing in the tree uses cgo
  # (`grep -rn 'import "C"'` is empty; sqlite is glebarez/modernc, pure Go), so build with
  # CGO_ENABLED=0 and upstream's own `netgo osusergo` tags. That yields static binaries, which the
  # public-file portal's minimal RootDirectory jail requires anyway. No UPX.
  env.CGO_ENABLED = "0";
  tags = [
    "netgo"
    "osusergo"
  ];

  subPackages = [
    "."
    "cmd/recasaos-public-files"
  ];
  renameBinaries.CasaOS = "casaos";
  repo = components.recasaos.repo;
  description = "ReCasaOS root service (files, storage, shares, system) and public-file portal";
  mainProgram = "casaos";

  # Guardrail patches (see docs/upstream-exclusions.md): self-update / self-kill routes removed,
  # host-management functions stripped from helper.sh, absolute /bin paths removed.
  patches = [
    ./patches/0001-disable-host-management-routes.patch
    ./patches/0002-helper-strip-host-management.patch
    ./patches/0003-bash-from-path.patch
  ];

  # Shell helpers carry no store paths at all. Commands stay bare (the service unit's PATH resolves
  # them) and the interpreter comes from `#!/usr/bin/env bash`; deliberately no patchShebangs.
  postPatch = ''
    for f in helper.sh usb-mount.sh assist.sh; do
      substituteInPlace "build/sysroot/usr/share/casaos/shell/$f" \
        --replace-fail '#!/bin/bash' '#!/usr/bin/env bash'
    done
  '';

  # The portal runs in a jail whose root is a directory (RootDirectory=), so the static binary has
  # to be present there as a real file, at the path upstream's `make build-public-files` uses.
  # (Appended to the recipe's postInstall through `extraPostInstall`.)
  extraPostInstall = ''
    jail="$out/share/casaos-sysroot/usr/lib/recasaos-public-files/rootfs/usr/bin"
    mkdir -p "$jail"
    cp "$out/bin/recasaos-public-files" "$jail/"
  '';
}
