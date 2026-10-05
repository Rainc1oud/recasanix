{
  mkCasaosGo,
  oapi-codegen-v1,
  components,
  src,
}:
# Runtime dependency, not a build one: the Docker CLI and the compose plugin. The NixOS module
# (task 3.1) supplies them through the unit's `path` (docker, docker-compose).
mkCasaosGo {
  pname = "casaos-app-management";
  # upstream: common/constants.go
  version = "0.4.16";
  inherit src;
  vendorHash = "sha256-P01D/KX2FAsJXvZrRXqc1rFyGvZJmzZ/6GuyKii1V2A=";
  patches = [ ./patches/0001-accept-bearer-authorization.patch ];
  subPackages = [ "." ];
  renameBinaries.CasaOS-AppManagement = "casaos-app-management";
  repo = components.recasaos-app-management.repo;
  description = "ReCasaOS app management: Docker/compose app lifecycle and app store";
  mainProgram = "casaos-app-management";

  # Upstream gitignores `codegen/` and produces it with `go generate`, which downloads
  # oapi-codegen@v1.12.4 and the message-bus OpenAPI spec from that repository's floating `main`
  # branch. Here the generator is a pinned build tool and the spec comes from the *pinned*
  # casaos-message-bus source, so the client always matches the message bus we ship.
  # postPatch also runs in the vendoring derivation (`go mod vendor` needs the generated package).
  nativeBuildInputs = [ oapi-codegen-v1 ];
  postPatch = ''
    mkdir -p codegen/message_bus
    oapi-codegen -generate types,server,spec -package codegen \
      api/app_management/openapi.yaml > codegen/app_management_api.go
    oapi-codegen -generate types,client -package message_bus \
      ${components.recasaos-message-bus.src}/api/message_bus/openapi.yaml > codegen/message_bus/api.go
  '';
}
