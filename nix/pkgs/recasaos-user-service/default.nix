{
  lib,
  mkCasaosGo,
  oapi-codegen-v1,
  components,
  src,
}:
mkCasaosGo {
  pname = "casaos-user-service";
  version = lib.removePrefix "v" components.recasaos-user-service.tag;
  inherit src;
  vendorHash = "sha256-V+QKM6Uhs9qgeQf/CDfF4c/Ny15uBbLNIDNw7X/SaEc=";
  subPackages = [ "." ];
  renameBinaries.CasaOS-UserService = "casaos-user-service";
  repo = components.recasaos-user-service.repo;
  description = "ReCasaOS user service: accounts, sessions, two-factor authentication and JWT issuance";
  mainProgram = "casaos-user-service";

  # local patch (docs/upstream-exclusions.md): no LocalStorage on ReCasaNix → no listener for it
  patches = [ ./patches/0001-drop-local-storage-listener.patch ];

  # `go generate` (gitignored codegen/): oapi-codegen@v1.12.4 from the network and the message-bus
  # spec from a floating URL → pinned generator, spec from the pinned message bus (see app-management).
  nativeBuildInputs = [ oapi-codegen-v1 ];
  postPatch = ''
    mkdir -p codegen/user_service codegen/message_bus
    oapi-codegen -package codegen api/user-service/openapi.yaml > codegen/user_service/user_service_api.go
    oapi-codegen -package message_bus \
      ${components.recasaos-message-bus.src}/api/message_bus/openapi.yaml > codegen/message_bus/api.go
  '';
}
