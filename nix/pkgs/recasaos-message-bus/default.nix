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
  vendorHash = "sha256-/SVLIsQKIgcMN8K0VzS1bJUpICg/V8ciGtir3n9D+k0=";
  subPackages = [ "." ];
  renameBinaries.CasaOS-MessageBus = "casaos-message-bus";
  repo = components.recasaos-message-bus.repo;
  description = "ReCasaOS message bus: event publish/subscribe between the CasaOS services";
  mainProgram = "casaos-message-bus";
}
