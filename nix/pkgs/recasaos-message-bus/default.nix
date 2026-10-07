{
  mkCasaosGo,
  components,
  src,
}:
mkCasaosGo {
  pname = "casaos-message-bus";
  # upstream: common/constants.go
  version = "0.4.4";
  inherit src;
  vendorHash = "sha256-VZ8cZq9ceiVI8JfB+KVHX+yBVyWHgdsQ+zRNS69XY/k=";
  subPackages = [ "." ];
  renameBinaries.CasaOS-MessageBus = "casaos-message-bus";
  repo = components.recasaos-message-bus.repo;
  description = "ReCasaOS message bus: event publish/subscribe between the CasaOS services";
  mainProgram = "casaos-message-bus";
}
