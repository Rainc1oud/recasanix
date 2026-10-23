{
  lib,
  mkCasaosGo,
  components,
  src,
}:
mkCasaosGo {
  pname = "casaos-message-bus";
  version = lib.removePrefix "v" components.recasaos-message-bus.tag;
  inherit src;
  vendorHash = "sha256-qXu+gVXDNZWyfqG5S77C6oZ5zvQEIrTj6msR13XZ1II=";
  subPackages = [ "." ];
  renameBinaries.CasaOS-MessageBus = "casaos-message-bus";
  repo = components.recasaos-message-bus.repo;
  description = "ReCasaOS message bus: event publish/subscribe between the CasaOS services";
  mainProgram = "casaos-message-bus";
}
