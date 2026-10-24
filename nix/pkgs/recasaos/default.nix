# casaos — the ReCasaOS root service (task 1.5).
{
  lib,
  mkCasaosGo,
  oapi-codegen-v1,
  components,
  src,
}:
mkCasaosGo {
  pname = "casaos";
  version = lib.removePrefix "v" components.recasaos.tag;
  inherit src;
  vendorHash = "sha256-gwNAE98PK1EqfiVpRT6N704+f4FciC5eIx4VWyqNR3w=";

  # Deviation from upstream (CGO_ENABLED=1, CGO_LDFLAGS=-static, UPX): nothing in the tree uses cgo
  # (`grep -rn 'import "C"'` is empty; sqlite is glebarez/modernc, pure Go) → CGO_ENABLED=0 with
  # upstream's own `netgo osusergo` tags; static binary. No UPX.
  env.CGO_ENABLED = "0";
  tags = [
    "netgo"
    "osusergo"
  ];

  subPackages = [ "." ];
  renameBinaries.CasaOS = "casaos";
  repo = components.recasaos.repo;
  description = "ReCasaOS root service (files, shares, system, stats, alerts)";
  mainProgram = "casaos";

  # Guardrail patch (docs/upstream-exclusions.md): host-management functions stripped from helper.sh,
  # absolute /bin paths removed. Routes: upstream switch `[server] ImageManaged` (no patch).
  patches = [ ./patches/0001-helper-strip-host-management.patch ];

  # codegen/ is gitignored, `go generate` fetches the generator and a floating message-bus spec →
  # pinned generator, spec from the pinned message bus (as app-management)
  nativeBuildInputs = [ oapi-codegen-v1 ];
  postPatch = ''
    mkdir -p codegen/message_bus
    oapi-codegen -generate types,server,spec -package codegen api/casaos/openapi.yaml > codegen/casaos_api.go
    oapi-codegen -generate types,client -package message_bus \
      ${components.recasaos-message-bus.src}/api/message_bus/openapi.yaml > codegen/message_bus/api.go
  '';
}
