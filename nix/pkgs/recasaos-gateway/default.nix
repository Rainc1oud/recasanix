# casaos-gateway — reference implementation of the Go-service recipe (task 1.1).
{
  lib,
  mkCasaosGo,
  components,
  src,
}:
mkCasaosGo {
  pname = "casaos-gateway";
  version = lib.removePrefix "v" components.recasaos-gateway.tag;
  inherit src;
  vendorHash = "sha256-rxIF9iSK6TCV+rS75xiHZjkQXo+VA4SbYRoRVC9gRJc=";
  subPackages = [ "." ];
  renameBinaries.CasaOS-Gateway = "casaos-gateway";
  repo = components.recasaos-gateway.repo;
  description = "ReCasaOS gateway: management listener, route registry, static UI server, optional TLS";
  mainProgram = "casaos-gateway";
}
