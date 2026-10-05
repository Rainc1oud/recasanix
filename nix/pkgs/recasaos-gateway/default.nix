# casaos-gateway — reference implementation of the Go-service recipe (task 1.1).
{
  mkCasaosGo,
  components,
  src,
}:
mkCasaosGo {
  pname = "casaos-gateway";
  # upstream: common/version.go
  version = "0.4.8";
  inherit src;
  vendorHash = "sha256-oVr1GrZac1uCDEs8+P1Y6gqir6UjaN+0RmPpioJg9F4=";
  subPackages = [ "." ];
  renameBinaries.CasaOS-Gateway = "casaos-gateway";
  repo = components.recasaos-gateway.repo;
  description = "ReCasaOS gateway: management listener, route registry and static UI server";
  mainProgram = "casaos-gateway";
}
